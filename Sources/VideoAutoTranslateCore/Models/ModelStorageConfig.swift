import Foundation

/// 模型存储位置模式
public enum ModelStorageLocationType: String, Codable, CaseIterable, Identifiable {
    case shared = "shared"         // 系统/用户共享目录 (~/.cache/huggingface/hub)
    case dedicated = "dedicated"   // 应用专属目录 (~/Library/Application Support/VideoAutoTranslate/models)
    case custom = "custom"         // 用户自定义目录 (如外接移动硬盘、NAS等)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shared:
            return "共享缓存目录 (与其他 AI 工具共用，节省空间)"
        case .dedicated:
            return "应用独立目录 (VideoAutoTranslate 专属隔离)"
        case .custom:
            return "自定义存储目录 (如外置高速移动硬盘、NAS)"
        }
    }
}

/// 模型下载源 / 镜像
public enum ModelDownloadMirror: String, Codable, CaseIterable, Identifiable {
    case hfMirror = "https://hf-mirror.com"
    case huggingFace = "https://huggingface.co"
    case modelScope = "https://modelscope.cn"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hfMirror:
            return "国内极速镜像 (hf-mirror.com - 推荐免代理)"
        case .huggingFace:
            return "官方源 (huggingface.co)"
        case .modelScope:
            return "魔搭社区源 (modelscope.cn)"
        }
    }
}

/// 预设模型定义
public struct ASRModelPreset: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let repoOrFileName: String
    public let sizeDescription: String
    public let approxSizeBytes: Int64
    public let isRepo: Bool
    public let note: String

    public init(
        id: String,
        displayName: String,
        repoOrFileName: String,
        sizeDescription: String,
        approxSizeBytes: Int64,
        isRepo: Bool,
        note: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repoOrFileName = repoOrFileName
        self.sizeDescription = sizeDescription
        self.approxSizeBytes = approxSizeBytes
        self.isRepo = isRepo
        self.note = note
    }

    public static let qwen3ASR = ASRModelPreset(
        id: "qwen3-asr-1.7b",
        displayName: "Qwen3-ASR (1.7B MLX 8-bit)",
        repoOrFileName: "mlx-community/Qwen3-ASR-1.7B-8bit",
        sizeDescription: "~1.8 GB",
        approxSizeBytes: 1_900_000_000,
        isRepo: true,
        note: "Apple Silicon Metal 硬件加速高精度语音识别（推荐）"
    )

    public static let qwen3Aligner = ASRModelPreset(
        id: "qwen3-aligner-0.6b",
        displayName: "Qwen3-ForcedAligner (0.6B 8-bit)",
        repoOrFileName: "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
        sizeDescription: "~600 MB",
        approxSizeBytes: 630_000_000,
        isRepo: true,
        note: "提供字词级别毫秒精确时间戳与发音对齐"
    )

    public static let allPresets: [ASRModelPreset] = [
        .qwen3ASR,
        .qwen3Aligner
    ]
}

/// 模型存储与下载配置模型
public struct ModelStorageConfig: Codable, Equatable {
    public var locationType: ModelStorageLocationType
    public var customDirectoryPath: String
    public var selectedMirror: ModelDownloadMirror

    public init(
        locationType: ModelStorageLocationType = .shared,
        customDirectoryPath: String = "",
        selectedMirror: ModelDownloadMirror = .hfMirror
    ) {
        self.locationType = locationType
        self.customDirectoryPath = customDirectoryPath
        self.selectedMirror = selectedMirror
    }
}
