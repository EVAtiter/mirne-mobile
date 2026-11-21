// アプリアイコンのマスター PNG（1024×1024・8-bit・sRGB）を描く。
// 使い方: swift scripts/make-icon.swift <出力.png> [standard|small]（scripts/make-icon.sh から呼ばれる）
//
// 図柄：淡い地に濃紺のテレビ（角丸の画面の枠と台）を置き、
// 白い画面に青い「mirne」の文字と、その下の中央に青い再生の三角。テレビの形は SF Symbols の tv と同じ形を自前で描く（SF Symbols は
// アプリのアイコンに使えない決まりのため）。mirne のアイコン（mirne の scripts/make-icon.swift）を元に、画面を縦に広げ
// （16:9 → 約 3:2）、文字を少し小さくして上へ寄せ、再生の三角を足した（色は mirne と同じ）。
// macOS 標準のタイル（余白 100px・ベース 824px・連続角丸 = ベース × 0.2247）の内側に描く。small は 16×16（1x）専用の
// 余白の狭い絵（macOS 27 は標準の余白の 16px を灰色の箱に入れることがある。使うかは make-icon.sh を参照）。
// 色は CGColor(srgbRed:) で起こす（CGColor(red:) は Generic RGB で、焼いた画素が指定より明るくなる）
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
/// macOS 標準の連続角丸の比（ベースに対する半径）
let cornerRatio: CGFloat = 0.2247
/// 標準の余白（macOS のアイコングリッド）
let standardMargin: CGFloat = 100
/// 16×16 専用の絵の余白（SendBlocker・Claude Meter で 16px が通った値）
let smallIconMargin: CGFloat = 64

let arguments = CommandLine.arguments
guard arguments.count > 1 else { fputs("使い方: make-icon.swift <出力.png> [standard|small]\n", stderr); exit(64) }
let out = arguments[1]
let variant = arguments.count > 2 ? arguments[2] : "standard"
let margin = variant == "small" ? smallIconMargin : standardMargin
let base = canvas - margin * 2
/// 絵柄の寸法は標準のベース（824px）で決めてあり、ベースの大きさに比例させる
let k = base / (canvas - standardMargin * 2)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// 地（上 → 下の縦グラデーション）
let tileTop = color(0xF4F8FC), tileBottom = color(0xD5E2EF)
/// テレビの枠と台
let frameColor = color(0x1B2A4A)
/// 画面
let screenColor = color(0xFFFFFF)
/// 文字
let labelColor = color(0x1C6FE0)
let labelText = "mirne"

/// テレビの寸法（標準のベース 824px のとき）
let frameWidth: CGFloat = 620 * k, frameStroke: CGFloat = 46 * k, frameCorner: CGFloat = 64 * k
/// 画面の枠の高さの幅に対する比（mirne は 16:9 = 0.5625。三角を入れるために縦に広げた）
let frameAspect: CGFloat = 0.68
let standWidth: CGFloat = 340 * k, standHeight: CGFloat = 40 * k, standGap: CGFloat = 42 * k
/// 文字の字面の幅（mirne は 400。三角の分だけ小さくした）
let labelWidth: CGFloat = 380 * k
/// 文字の字面の中心を、画面の中心から上へずらす量
let labelRaise: CGFloat = 48 * k
/// 再生の三角の高さと、中心を画面の中心から下へずらす量
let triangleHeight: CGFloat = 92 * k, triangleDrop: CGFloat = 78 * k
/// 三角の幅の高さに対する比・見た目の重心を合わせるために右へ寄せる比（幅に対して）・角を丸める線の太さ（高さに対して）
let triangleWidthRatio: CGFloat = 0.9, triangleOpticalShift: CGFloat = 0.08, triangleRoundRatio: CGFloat = 0.18

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let n = Int(canvas)
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

/// 文字を、字面の幅が width になる大きさで、字面の中心が point に来るように描く（SF Pro Rounded の Bold）
func drawLabel(_ text: String, color textColor: CGColor, centeredAt point: CGPoint, width: CGFloat) {
    func font(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .bold)
        return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    }
    func line(size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font(size: size), .foregroundColor: NSColor(cgColor: textColor)!,
        ]))
    }
    let reference: CGFloat = 100
    let measured = CTLineGetImageBounds(line(size: reference), ctx).width
    let typeset = line(size: reference * width / measured)
    let bounds = CTLineGetImageBounds(typeset, ctx)
    ctx.textPosition = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    CTLineDraw(typeset, ctx)
}

/// 再生の三角（右向き・角を丸める）を、中心が point に来るように描く
func drawPlayTriangle(color fill: CGColor, centeredAt point: CGPoint, height: CGFloat) {
    let width = height * triangleWidthRatio
    let center = CGPoint(x: point.x + width * triangleOpticalShift, y: point.y)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - width / 2, y: center.y + height / 2))
    path.addLine(to: CGPoint(x: center.x + width / 2, y: center.y))
    path.addLine(to: CGPoint(x: center.x - width / 2, y: center.y - height / 2))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.setStrokeColor(fill)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(height * triangleRoundRatio)
    ctx.drawPath(using: .fillStroke)
}

// タイル（連続角丸・縦のグラデーション）
let tile = CGRect(x: margin, y: margin, width: base, height: base)
ctx.saveGState()
ctx.addPath(roundedPath(tile, radius: base * cornerRatio))
ctx.clip()
let gradient = CGGradient(colorsSpace: srgb, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// テレビ（枠と台をひとまとまりにして、タイルの上下の中央に置く）
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let frameHeight = frameWidth * frameAspect
let groupHeight = frameHeight + standGap + standHeight
let frame = CGRect(x: center.x - frameWidth / 2, y: center.y + groupHeight / 2 - frameHeight, width: frameWidth, height: frameHeight)
let framePath = roundedPath(frame.insetBy(dx: frameStroke / 2, dy: frameStroke / 2), radius: frameCorner)
ctx.addPath(framePath)
ctx.setFillColor(screenColor)
ctx.fillPath()
ctx.addPath(framePath)
ctx.setStrokeColor(frameColor)
ctx.setLineWidth(frameStroke)
ctx.strokePath()
let stand = CGRect(x: center.x - standWidth / 2, y: frame.minY - standGap - standHeight, width: standWidth, height: standHeight)
ctx.addPath(roundedPath(stand, radius: standHeight / 2))
ctx.setFillColor(frameColor)
ctx.fillPath()

// 画面の文字（上寄り）と再生の三角（下の中央）
drawLabel(labelText, color: labelColor, centeredAt: CGPoint(x: center.x, y: frame.midY + labelRaise), width: labelWidth)
drawPlayTriangle(color: labelColor, centeredAt: CGPoint(x: center.x, y: frame.midY - triangleDrop), height: triangleHeight)

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
