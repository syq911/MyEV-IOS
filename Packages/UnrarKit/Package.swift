// swift-tools-version:5.3
//
//  UnrarKit（vendored）
//
//  为什么把源码放进仓库而不是当远程 SPM 依赖：
//  上游的 SPM 支持（ZHK1024/UnrarKit-Swift-Package）清单里 `sources` 只列了
//  `Libraries/unrar/dll.cpp` 一个实现文件，而 unrar 的实现散在 83 个 .cpp 里，
//  照那个清单编译必然在链接阶段报 undefined symbols。远程依赖又不能改清单，
//  所以这里把源码收进来、用一份**完整**的 sources 清单编译。
//
//  许可：UnrarKit 为 BSD-2-Clause（见 LICENSE），其内嵌的 unrar 源码
//  遵循 RARLAB 的 UnRAR 许可（允许随应用分发、允许修改，禁止用于实现 RAR 压缩）。
//
import PackageDescription

let package = Package(
    name: "UnrarKit",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "UnrarKit", targets: ["UnrarKit"])
    ],
    targets: [
        .target(
            name: "UnrarKit",
            path: ".",
            exclude: [
                "LICENSE",
                // unrar 自带 Windows 专属实现：它们在 iOS/macOS 上没有对应类型
                "Libraries/unrar/win32acl.cpp",
                "Libraries/unrar/win32lnk.cpp",
                "Libraries/unrar/win32stm.cpp",
                // 非源代码文件，列出来免得 SwiftPM 报 unhandled files
                "Libraries/unrar/makefile",
                "Libraries/unrar/readme.txt",
                "Libraries/unrar/license.txt",
                "Libraries/unrar/dll.rc",
                "Libraries/unrar/dll_nocrypt.def"
            ],
            sources: [
                "Classes",
                "Libraries/unrar"
            ],
            publicHeadersPath: "Classes/include",
            cxxSettings: [
                .headerSearchPath("Libraries/unrar"),
                .headerSearchPath("Classes"),
                .headerSearchPath("Classes/Categories"),
                .define("RARDLL"),
                .define("UNRAR"),
                .define("_UNIX"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("LARGEFILE_SOURCE")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ],
    cxxLanguageStandard: .cxx11
)
