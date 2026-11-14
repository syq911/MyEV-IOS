// swift-tools-version:5.3
//
//  UnrarKit（vendored：unrar 源码 + 一层极小的 C 接口）
//
//  为什么源码在仓库里：上游的 SPM 支持（ZHK1024/UnrarKit-Swift-Package）清单里
//  `sources` 只列了 `dll.cpp`，其余实现散在几十个 .cpp 里，照那个清单编译
//  必然链接失败；远程依赖又改不了清单。
//
//  为什么不用它的 ObjC 封装：公开头文件里 `#import "raros.hpp"` / `"dll.hpp"`，
//  把 unrar 内部头暴露到了模块边界；SwiftPM 生成 Clang module 时不带目标内的
//  header search path，模块构建阶段就报 'raros.hpp' file not found。
//  改成只暴露 Shim/URShim.h（纯 C，6 个函数）。
//
//  ⚠️ sources 必须逐个列，不能写目录：unrar 目录里 83 个 .cpp 中有 32 个是
//  「被别的文件 #include 的碎片」（unpack15/20/30/50、crypt1..5、coder、model、
//  suballoc、uowners…），单独编译会报 unknown type name 'Archive'。
//  也不能照抄 makefile 的 OBJECTS：那份清单漏了 qopen.cpp，链接时会缺
//  QuickOpen::* 符号。下面这份 = 全部 .cpp 减去碎片再减去 win32 专属。
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
                "Libraries/unrar/archive.cpp",
                "Libraries/unrar/arcread.cpp",
                "Libraries/unrar/blake2s.cpp",
                "Libraries/unrar/cmddata.cpp",
                "Libraries/unrar/consio.cpp",
                "Libraries/unrar/crc.cpp",
                "Libraries/unrar/crypt.cpp",
                "Libraries/unrar/dll.cpp",
                "Libraries/unrar/encname.cpp",
                "Libraries/unrar/errhnd.cpp",
                "Libraries/unrar/extinfo.cpp",
                "Libraries/unrar/extract.cpp",
                "Libraries/unrar/filcreat.cpp",
                "Libraries/unrar/file.cpp",
                "Libraries/unrar/filefn.cpp",
                "Libraries/unrar/filestr.cpp",
                "Libraries/unrar/find.cpp",
                "Libraries/unrar/getbits.cpp",
                "Libraries/unrar/global.cpp",
                "Libraries/unrar/hash.cpp",
                "Libraries/unrar/headers.cpp",
                "Libraries/unrar/isnt.cpp",
                "Libraries/unrar/list.cpp",
                "Libraries/unrar/match.cpp",
                "Libraries/unrar/options.cpp",
                "Libraries/unrar/pathfn.cpp",
                "Libraries/unrar/qopen.cpp",
                "Libraries/unrar/rar.cpp",
                "Libraries/unrar/rarpch.cpp",
                "Libraries/unrar/rarvm.cpp",
                "Libraries/unrar/rawread.cpp",
                "Libraries/unrar/rdwrfn.cpp",
                "Libraries/unrar/recvol.cpp",
                "Libraries/unrar/resource.cpp",
                "Libraries/unrar/rijndael.cpp",
                "Libraries/unrar/rs.cpp",
                "Libraries/unrar/rs16.cpp",
                "Libraries/unrar/scantree.cpp",
                "Libraries/unrar/secpassword.cpp",
                "Libraries/unrar/sha1.cpp",
                "Libraries/unrar/sha256.cpp",
                "Libraries/unrar/smallfn.cpp",
                "Libraries/unrar/strfn.cpp",
                "Libraries/unrar/strlist.cpp",
                "Libraries/unrar/system.cpp",
                "Libraries/unrar/threadpool.cpp",
                "Libraries/unrar/timefn.cpp",
                "Libraries/unrar/ui.cpp",
                "Libraries/unrar/unicode.cpp",
                "Libraries/unrar/unpack.cpp",
                "Libraries/unrar/volume.cpp",
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
