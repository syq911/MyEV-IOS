// swift-tools-version:5.3
//
//  UnrarKit（vendored）
//
//  为什么把源码放进仓库而不是当远程 SPM 依赖：
//  上游的 SPM 支持（ZHK1024/UnrarKit-Swift-Package）清单里 `sources` 只列了
//  `Libraries/unrar/dll.cpp`，而 unrar 的实现分散在几十个 .cpp 里，照那个清单
//  编译必然在链接阶段报 undefined symbols。远程依赖又改不了清单，所以把源码
//  收进来、用**上游 makefile 的 OBJECTS 清单**原样编译。
//
//  注意：unrar 的目录里混着大量「被 #include 的 .cpp 碎片」
//  （unpack15/20/30/50、crypt1..5、coder、model、suballoc、uowners…），
//  它们不能单独编译。sources 不能写目录，只能逐个列 —— 写目录会把碎片也带上，
//  编译出一堆 "unknown type name 'Archive'" 之类的错误。
//
//  许可：UnrarKit 为 BSD-2-Clause（见 LICENSE），内嵌 unrar 遵循 RARLAB 的
//  UnRAR 许可（允许随应用分发与修改，禁止用于实现 RAR 压缩）。
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
                "Classes"
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
