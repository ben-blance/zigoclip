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
)

// bitmapInfoHeaderSize is the size of a BITMAPINFOHEADER, which is
// what CF_DIB clipboard data starts with (no BITMAPFILEHEADER, unlike
// a .bmp file on disk).
const bitmapInfoHeaderSize = 40

// DecodeDIB parses a raw CF_DIB clipboard blob into an image.Image.
// Only uncompressed 24-bit and 32-bit BGR(A) are supported, which
// covers the vast majority of images placed on the Windows clipboard
// (screenshots, Paint, browser image copies). Anything else — indexed
// color, RLE compression — returns an error rather than corrupting
// output.
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

	if compression != 0 {
		return nil, fmt.Errorf("imagecodec: unsupported compression %d", compression)
	}

	if bitCount != 24 && bitCount != 32 {
		return nil, fmt.Errorf("imagecodec: unsupported bit depth %d", bitCount)
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

	pixelOffset := int(headerSize) // no color table for 24/32-bit uncompressed
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

			a := byte(255)
			if bytesPerPixel == 4 {
				a = pixels[i+3]
			}

			img.SetNRGBA(x, y, color.NRGBA{
				R: pixels[i+2],
				G: pixels[i+1],
				B: pixels[i],
				A: a,
			})
		}
	}

	return img, nil
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