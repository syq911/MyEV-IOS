// swift-tools-version:5.3
//
//  UnrarKit（vendored，只保留 unrar + 一个极小的 C 接口）
//
//  为什么源码在仓库里：上游的 SPM 支持（ZHK1024/UnrarKit-Swift-Package）清单里
//  `sources` 只列了 `Libraries/unrar/dll.cpp`，其余实现散在几十个 .cpp 里，
//  照那个清单编译必然链接失败；远程依赖又改不了清单。
//
//  为什么不用它的 ObjC 封装（Classes/）：那些公开头文件 `#import "raros.hpp"`、
//  `"dll.hpp"`，把 unrar 内部头暴露到了模块边界，SwiftPM 生成 Clang module 时
//  不带目标内 header search path，直接报 'raros.hpp' file not found。
//  因此改为只暴露 Shim/URShim.h 这一层纯 C 接口。
//
//  注意 sources 只能逐个列，不能写目录：unrar 目录里混着三十多个
//  「被 #include 的 .cpp 碎片」（unpack15/20/30/50、crypt1..5、coder、model…），
//  单独编译会报 unknown type name 'Archive'。
//  下面这份清单来自上游 makefile 的 OBJECTS。
//
//  许可：内嵌 unrar 遵循 RARLAB 的 UnRAR 许可（允许随应用分发与修改，
//  禁止用于实现 RAR 压缩）；UnrarKit 原有部分为 BSD-2-Clause（见 LICENSE）。
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
                "LICENSE"
            ],
            sources: [
                "Libraries/unrar/rar.cpp",
                "Libraries/unrar/strlist.cpp",
                "Libraries/unrar/strfn.cpp",
                "Libraries/unrar/pathfn.cpp",
                "Libraries/unrar/smallfn.cpp",
                "Libraries/unrar/global.cpp",
                "Libraries/unrar/file.cpp",
                "Libraries/unrar/filefn.cpp",
                "Libraries/unrar/filcreat.cpp",
                "Libraries/unrar/archive.cpp",
                "Libraries/unrar/arcread.cpp",
                "Libraries/unrar/unicode.cpp",
                "Libraries/unrar/system.cpp",
                "Libraries/unrar/isnt.cpp",
                "Libraries/unrar/crypt.cpp",
                "Libraries/unrar/crc.cpp",
                "Libraries/unrar/rawread.cpp",
                "Libraries/unrar/encname.cpp",
                "Libraries/unrar/resource.cpp",
                "Libraries/unrar/match.cpp",
                "Libraries/unrar/timefn.cpp",
                "Libraries/unrar/rdwrfn.cpp",
                "Libraries/unrar/consio.cpp",
                "Libraries/unrar/options.cpp",
                "Libraries/unrar/errhnd.cpp",
                "Libraries/unrar/rarvm.cpp",
                "Libraries/unrar/secpassword.cpp",
                "Libraries/unrar/rijndael.cpp",
                "Libraries/unrar/getbits.cpp",
                "Libraries/unrar/sha1.cpp",
                "Libraries/unrar/sha256.cpp",
                "Libraries/unrar/blake2s.cpp",
                "Libraries/unrar/hash.cpp",
                "Libraries/unrar/extinfo.cpp",
                "Libraries/unrar/extract.cpp",
                "Libraries/unrar/volume.cpp",
                "Libraries/unrar/list.cpp",
                "Libraries/unrar/find.cpp",
                "Libraries/unrar/unpack.cpp",
                "Libraries/unrar/headers.cpp",
                "Libraries/unrar/threadpool.cpp",
                "Libraries/unrar/rs16.cpp",
                "Libraries/unrar/cmddata.cpp",
                "Libraries/unrar/ui.cpp",
                "Libraries/unrar/dll.cpp",
                "Shim/URShim.cpp"
            ],
            publicHeadersPath: "Shim",
            cxxSettings: [
                .headerSearchPath("Libraries/unrar"),
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
