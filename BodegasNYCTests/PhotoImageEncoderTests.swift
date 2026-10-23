//
//  PhotoImageEncoderTests.swift
//  BodegasNYCTests
//
//  Pure image processing, no networking — standalone top-level suite per
//  this codebase's convention (see `BodegaClusteringTests`). Inputs are
//  generated in-memory with UIGraphicsImageRenderer, so no fixture files.
//

import Foundation
import ImageIO
import Testing
import UIKit

@testable import BodegasNYC

@Suite
struct PhotoImageEncoderTests {
    /// A solid-color PNG of exactly `width` x `height` pixels (scale 1).
    private static func makePNG(width: CGFloat, height: CGFloat) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.pngData())
    }

    private static func pixelSize(of data: Data) throws -> CGSize {
        let image = try #require(UIImage(data: data))
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    @Test func largeLandscapeImageShrinksToTheLongEdgeLimit() throws {
        let output = try #require(PhotoImageEncoder.encode(Self.makePNG(width: 3200, height: 2400)))

        #expect(try Self.pixelSize(of: output) == CGSize(width: 1600, height: 1200))
    }

    @Test func largePortraitImageShrinksOnItsLongEdgeToo() throws {
        let output = try #require(PhotoImageEncoder.encode(Self.makePNG(width: 1000, height: 4000)))

        #expect(try Self.pixelSize(of: output) == CGSize(width: 400, height: 1600))
    }

    @Test func smallImageKeepsItsSize() throws {
        let output = try #require(PhotoImageEncoder.encode(Self.makePNG(width: 800, height: 600)))

        #expect(try Self.pixelSize(of: output) == CGSize(width: 800, height: 600))
    }

    @Test func outputIsJPEG() throws {
        let output = try #require(PhotoImageEncoder.encode(Self.makePNG(width: 200, height: 100)))

        #expect(output.count > 2)
        #expect(output.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func undecodableDataReturnsNil() {
        #expect(PhotoImageEncoder.encode(Data("definitely not an image".utf8)) == nil)
        #expect(PhotoImageEncoder.encode(Data()) == nil)
    }

    // MARK: ImageIO behaviors (#107 eng C1)

    /// A `width` x `height` JPEG tagged with EXIF `orientation`.
    private static func makeOrientedJPEG(width: Int, height: Int, orientation: UInt32) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(UIColor.systemOrange.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The RGB of the pixel at the top-left of `data`'s image.
    private static func topLeftRGB(of data: Data) throws -> (Int, Int, Int) {
        let image = try #require(UIImage(data: data)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// protects: EXIF orientation is baked into the pixels, so a rotated camera photo uploads upright (eng C1).
    /// fails_when: the output keeps the stored (sideways) dimensions.
    /// no_claim: the pixel content's rotation direction (dimensions only).
    @Test func exifOrientationIsBakedIn() throws {
        let rotated = try Self.makeOrientedJPEG(width: 3200, height: 1600, orientation: 6)

        let output = try #require(PhotoImageEncoder.encode(rotated))

        #expect(try Self.pixelSize(of: output) == CGSize(width: 800, height: 1600))
    }

    /// protects: transparency is flattened onto white, not black (JPEG has no alpha).
    /// fails_when: a transparent PNG comes out dark.
    /// no_claim: colour accuracy beyond near-white.
    @Test func transparentPixelsBecomeWhite() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { _ in }
        let png = try #require(clear.pngData())

        let output = try #require(PhotoImageEncoder.encode(png))

        let (red, green, blue) = try Self.topLeftRGB(of: output)
        #expect(red > 245 && green > 245 && blue > 245)
    }

    /// protects: `prepare` returns the upload JPEG plus a thumbnail no longer than its long-edge cap, never
    /// upscaled (eng C1).
    /// fails_when: the thumbnail is full size, upscaled, or the JPEG differs from `encode`'s sizing.
    /// no_claim: thumbnail quality.
    @Test func prepareMakesTheUploadJPEGAndABoundedThumbnail() throws {
        let large = try #require(PhotoImageEncoder.prepare(Self.makePNG(width: 3200, height: 2400)))
        #expect(try Self.pixelSize(of: large.jpeg) == CGSize(width: 1600, height: 1200))
        let thumb = try #require(large.thumbnail.cgImage)
        #expect(max(thumb.width, thumb.height) == 256)

        let small = try #require(PhotoImageEncoder.prepare(Self.makePNG(width: 100, height: 50)))
        #expect(small.thumbnail.cgImage?.width == 100)
        #expect(PhotoImageEncoder.prepare(Data("nope".utf8)) == nil)
    }

    @Test func targetSizeNeverUpscales() {
        #expect(PhotoImageEncoder.targetSize(for: CGSize(width: 1600, height: 900)) == CGSize(width: 1600, height: 900))
        #expect(PhotoImageEncoder.targetSize(for: CGSize(width: 10, height: 10)) == CGSize(width: 10, height: 10))
    }
}
