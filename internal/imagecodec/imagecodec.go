// Package imagecodec converts between the raw CF_DIB blob Zig relays
// from the Windows clipboard and PNG, which is what actually goes
// out over TCP. Zig never touches image pixels — it only extracts
// and re-injects the clipboard's own CF_DIB bytes; all encoding
// happens here since Go's stdlib already has a correct PNG codec.
package imagecodec

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math/bits"
)

// bitmapInfoHeaderSize is the size of a BITMAPINFOHEADER, which is
// what CF_DIB clipboard data starts with (no BITMAPFILEHEADER, unlike
// a .bmp file on disk).
const bitmapInfoHeaderSize = 40

// DecodeDIB parses a raw CF_DIB clipboard blob into an image.Image.
// Supports uncompressed 24/32-bit BI_RGB and 32-bit BI_BITFIELDS
// (the form most apps use for a 32-bit image with real alpha, since
// the base BITMAPINFOHEADER has no alpha field of its own) — between
// them these cover the vast majority of images placed on the Windows
// clipboard. Indexed color and RLE compression return an error
// rather than corrupting output.
func DecodeDIB(data []byte) (image.Image, error) {
	if len(data) < bitmapInfoHeaderSize {
		return nil, fmt.Errorf("imagecodec: header too short (%d bytes)", len(data))
	}

	headerSize := binary.LittleEndian.Uint32(data[0:4])
	if headerSize < bitmapInfoHeaderSize {
		return nil, fmt.Errorf("imagecodec: unsupported header size %d", headerSize)
	}

	width := int(int32(binary.LittleEndian.Uint32(data[4:8])))
	height := int(int32(binary.LittleEndian.Uint32(data[8:12])))
	bitCount := binary.LittleEndian.Uint16(data[14:16])
	compression := binary.LittleEndian.Uint32(data[16:20])

	if bitCount != 24 && bitCount != 32 {
		return nil, fmt.Errorf("imagecodec: unsupported bit depth %d", bitCount)
	}

	// Figure out where each channel's bits live and where pixel data
	// starts. BI_RGB uses the implicit standard byte order regardless
	// of header size; BI_BITFIELDS carries explicit masks, either
	// appended after a plain 40-byte header or embedded at fixed
	// offsets in an extended (V4/V5) header.
	var rMask, gMask, bMask, aMask uint32
	var pixelOffset int

	switch compression {
	case 0: // BI_RGB
		bMask, gMask, rMask = 0x000000FF, 0x0000FF00, 0x00FF0000
		if bitCount == 32 {
			aMask = 0xFF000000
		}
		pixelOffset = int(headerSize)

	case 3: // BI_BITFIELDS
		switch {
		case headerSize == bitmapInfoHeaderSize:
			// Three DWORD masks (R,G,B — no alpha in this form)
			// follow the header, in the space a color table would
			// otherwise occupy.
			pixelOffset = int(headerSize) + 12
			if len(data) < pixelOffset {
				return nil, fmt.Errorf("imagecodec: truncated bitfield masks")
			}
			rMask = binary.LittleEndian.Uint32(data[headerSize : headerSize+4])
			gMask = binary.LittleEndian.Uint32(data[headerSize+4 : headerSize+8])
			bMask = binary.LittleEndian.Uint32(data[headerSize+8 : headerSize+12])

		case headerSize >= 108: // BITMAPV4HEADER or BITMAPV5HEADER
			if len(data) < 56 {
				return nil, fmt.Errorf("imagecodec: truncated V4/V5 header")
			}
			rMask = binary.LittleEndian.Uint32(data[40:44])
			gMask = binary.LittleEndian.Uint32(data[44:48])
			bMask = binary.LittleEndian.Uint32(data[48:52])
			aMask = binary.LittleEndian.Uint32(data[52:56])
			pixelOffset = int(headerSize)

		default:
			return nil, fmt.Errorf("imagecodec: unsupported header size %d for BI_BITFIELDS", headerSize)
		}

	default:
		return nil, fmt.Errorf("imagecodec: unsupported compression %d", compression)
	}

	topDown := height < 0
	if topDown {
		height = -height
	}

	if width <= 0 || height <= 0 {
		return nil, fmt.Errorf("imagecodec: invalid dimensions %dx%d", width, height)
	}

	bytesPerPixel := int(bitCount) / 8
	stride := ((width*int(bitCount) + 31) / 32) * 4 // rows are padded to 4 bytes

	needed := pixelOffset + stride*height

	if len(data) < needed {
		return nil, fmt.Errorf("imagecodec: payload too short: have %d need %d", len(data), needed)
	}

	pixels := data[pixelOffset:]

	img := image.NewNRGBA(image.Rect(0, 0, width, height))

	for y := 0; y < height; y++ {
		// DIB rows are bottom-up unless the header height is
		// negative (top-down).
		srcRow := y
		if !topDown {
			srcRow = height - 1 - y
		}

		rowStart := srcRow * stride

		for x := 0; x < width; x++ {
			i := rowStart + x*bytesPerPixel

			var pixel uint32
			if bytesPerPixel == 4 {
				pixel = binary.LittleEndian.Uint32(pixels[i : i+4])
			} else {
				pixel = uint32(pixels[i]) | uint32(pixels[i+1])<<8 | uint32(pixels[i+2])<<16
			}

			a := byte(255)
			if aMask != 0 {
				a = extractChannel(pixel, aMask)
			}

			img.SetNRGBA(x, y, color.NRGBA{
				R: extractChannel(pixel, rMask),
				G: extractChannel(pixel, gMask),
				B: extractChannel(pixel, bMask),
				A: a,
			})
		}
	}

	return img, nil
}

// extractChannel pulls an 8-bit channel value out of a packed pixel
// using a bitmask, scaling up if the mask is narrower than 8 bits
// (e.g. 5/6-bit channels in a 16-bit format) and truncating if wider.
func extractChannel(pixel, mask uint32) byte {
	if mask == 0 {
		return 0
	}

	shift := bits.TrailingZeros32(mask)
	width := bits.OnesCount32(mask)

	value := (pixel & mask) >> shift

	switch {
	case width < 8:
		maxVal := uint32(1)<<uint(width) - 1
		value = value * 255 / maxVal
	case width > 8:
		value = value >> uint(width-8)
	}

	return byte(value)
}

// EncodeDIB converts an image.Image into a raw CF_DIB blob (32-bit
// BGRA, top-down) ready to hand back to Zig for SetClipboardData.
func EncodeDIB(img image.Image) ([]byte, error) {
	bounds := img.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()

	if width <= 0 || height <= 0 {
		return nil, fmt.Errorf("imagecodec: invalid image dimensions %dx%d", width, height)
	}

	stride := width * 4

	buf := make([]byte, bitmapInfoHeaderSize+stride*height)

	binary.LittleEndian.PutUint32(buf[0:4], bitmapInfoHeaderSize)
	binary.LittleEndian.PutUint32(buf[4:8], uint32(width))
	// Negative height marks the DIB top-down, matching the row order
	// written below, so no manual flip is needed.
	binary.LittleEndian.PutUint32(buf[8:12], uint32(int32(-height)))
	binary.LittleEndian.PutUint16(buf[12:14], 1)  // biPlanes
	binary.LittleEndian.PutUint16(buf[14:16], 32) // biBitCount
	// biCompression (BI_RGB=0), biSizeImage, biXPelsPerMeter,
	// biYPelsPerMeter, biClrUsed, biClrImportant are left zero.

	pixels := buf[bitmapInfoHeaderSize:]

	for y := 0; y < height; y++ {
		rowStart := y * stride

		for x := 0; x < width; x++ {
			// .RGBA() always returns alpha-premultiplied values
			// regardless of the source image's representation, so we
			// convert through NRGBA to get back straight (DIB/PNG
			// native) values instead of hand-rolling that math.
			c := color.NRGBAModel.Convert(img.At(bounds.Min.X+x, bounds.Min.Y+y)).(color.NRGBA)

			i := rowStart + x*4

			pixels[i] = c.B
			pixels[i+1] = c.G
			pixels[i+2] = c.R
			pixels[i+3] = c.A
		}
	}

	return buf, nil
}

// EncodePNG compresses img for network transfer.
func EncodePNG(img image.Image) ([]byte, error) {
	var buf bytes.Buffer

	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

// DecodePNG reverses EncodePNG.
func DecodePNG(data []byte) (image.Image, error) {
	return png.Decode(bytes.NewReader(data))
}