// PCL XL binary stream tag values, from HP's "PCL XL Feature Reference, Protocol Class 2.0/2.1/3.0".
// Only the subset a raster driver emits (and the reader must recognise) is named here.

/// Data-type tags: the byte that precedes every value in the stream.
public enum PCLXLDataTag: UInt8, Sendable, CaseIterable {
    case ubyte = 0xC0, uint16 = 0xC1, uint32 = 0xC2, sint16 = 0xC3, sint32 = 0xC4, real32 = 0xC5
    case ubyteArray = 0xC8, uint16Array = 0xC9, uint32Array = 0xCA
    case sint16Array = 0xCB, sint32Array = 0xCC, real32Array = 0xCD
    case ubyteXY = 0xD0, uint16XY = 0xD1, uint32XY = 0xD2, sint16XY = 0xD3, sint32XY = 0xD4, real32XY = 0xD5
    case ubyteBox = 0xE0, uint16Box = 0xE1, uint32Box = 0xE2, sint16Box = 0xE3, sint32Box = 0xE4, real32Box = 0xE5
}

/// Structural tags.
public enum PCLXLStructureTag {
    /// Followed by a one-byte attribute id.
    public static let attributeUByte: UInt8 = 0xF8
    /// Followed by a two-byte attribute id (unused by this driver).
    public static let attributeUInt16: UInt8 = 0xF9
    /// Embedded data follows: uint32 little-endian length, then that many bytes.
    public static let dataLength: UInt8 = 0xFA
    /// Embedded data follows: one-byte length, then that many bytes.
    public static let dataLengthByte: UInt8 = 0xFB
}

public enum PCLXLOperator: UInt8, Sendable, CaseIterable {
    case beginSession = 0x41
    case endSession = 0x42
    case beginPage = 0x43
    case endPage = 0x44
    case comment = 0x47
    case openDataSource = 0x48
    case closeDataSource = 0x49
    case popGS = 0x60
    case pushGS = 0x61
    case setColorSpace = 0x6A
    case setCursor = 0x6B
    case setPageOrigin = 0x75
    case beginImage = 0xB0
    case readImage = 0xB1
    case endImage = 0xB2
}

public enum PCLXLAttribute: UInt8, Sendable, CaseIterable {
    case paletteDepth = 2
    case colorSpace = 3
    case paletteData = 6
    case mediaSize = 37
    case mediaSource = 38
    case mediaType = 39
    case orientation = 40
    case customMediaSize = 47
    case customMediaSizeUnits = 48
    case pageCopies = 49
    case simplexPageMode = 52
    case duplexPageMode = 53
    case duplexPageSide = 54
    case point = 76
    case colorDepth = 98
    case blockHeight = 99
    case colorMapping = 100
    case compressMode = 101
    case destinationSize = 103
    case sourceHeight = 107
    case sourceWidth = 108
    case startLine = 109
    case padBytesMultiple = 110
    case blockByteLength = 111
    case commentData = 129
    case dataOrg = 130
    case measure = 134
    case sourceType = 136
    case unitsPerMeasure = 137
    case errorReport = 143
}

// Attribute enumerations. Each is sent as a ubyte.

public enum PCLXLColorSpace: UInt8, Sendable { case gray = 1, rgb = 2, sRGB = 6 }
public enum PCLXLColorDepth: UInt8, Sendable { case bits1 = 0, bits4 = 1, bits8 = 2 }
public enum PCLXLColorMapping: UInt8, Sendable { case directPixel = 0, indexedPixel = 1 }
public enum PCLXLCompressMode: UInt8, Sendable { case none = 0, rle = 1, jpeg = 2, deltaRow = 3 }
public enum PCLXLDataOrg: UInt8, Sendable { case binaryHighByteFirst = 0, binaryLowByteFirst = 1 }
public enum PCLXLDataSource: UInt8, Sendable { case `default` = 0 }
public enum PCLXLMeasure: UInt8, Sendable { case inch = 0, millimeter = 1, tenthsOfAMillimeter = 2 }
public enum PCLXLErrorReport: UInt8, Sendable { case none = 0, backChannel = 1, errorPage = 2, backChannelAndErrorPage = 3 }
public enum PCLXLOrientation: UInt8, Sendable { case portrait = 0, landscape = 1, reversePortrait = 2, reverseLandscape = 3 }
public enum PCLXLDuplexPageMode: UInt8, Sendable { case horizontalBinding = 0, verticalBinding = 1 }
public enum PCLXLDuplexPageSide: UInt8, Sendable { case front = 0, back = 1 }
public enum PCLXLSimplexPageMode: UInt8, Sendable { case frontSide = 0 }

public enum PCLXLMediaSource: UInt8, Sendable {
    case `default` = 0, autoSelect = 1, manualFeed = 2, multiPurposeTray = 3
    case upperCassette = 4, lowerCassette = 5, envelopeTray = 6
}

/// Standard MediaSize enumeration. Sizes without an entry are sent as CustomMediaSize.
public enum PCLXLMediaSize: UInt8, Sendable {
    case letter = 0, legal = 1, a4 = 2, executive = 3, ledger = 4, a3 = 5
    case com10Envelope = 6, monarchEnvelope = 7, c5Envelope = 8, dlEnvelope = 9
    /// `isoB5` is HP's "eB5Envelope" (176 × 250 mm). Code 13 ("eB5Paper", class 2.1) is a second
    /// name for JIS B5 and is deliberately not used.
    case jisB4 = 10, jisB5 = 11, isoB5 = 12
    case jPostcard = 14, jDoublePostcard = 15, a5 = 16, a6 = 17, jisB6 = 18
}
