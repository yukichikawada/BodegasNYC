//
//  PhotoImageEncoderTests.swift
//  BodegasNYCTests
//
//  Pure image processing, no networking — standalone top-level suite per
//  this codebase's convention (see `BodegaClusteringTests`). Inputs are
//  generated in-memory with UIGraphicsImageRenderer, so no fixture files.
//

import Foundation
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

    @Test func targetSizeNeverUpscales() {
        #expect(PhotoImageEncoder.targetSize(for: CGSize(width: 1600, height: 900)) == CGSize(width: 1600, height: 900))
        #expect(PhotoImageEncoder.targetSize(for: CGSize(width: 10, height: 10)) == CGSize(width: 10, height: 10))
    }
}
