#!/usr/bin/env python3
"""Write ClaunttyMac.xcodeproj/project.pbxproj, the macOS app's project.

The Mac app shares the iOS app's code through synchronized folders: all of
Clauntty/Core and Clauntty/Models, minus the iOS-only files in MAC_EXCLUDED.
New files in those folders (or in ClaunttyMac/) need no project change; rerun
this only to change what's excluded, packages or build settings.

Usage: python3 scripts/gen-mac-project.py
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# iOS-only code under Clauntty/Core: whole folders, or single files.
MAC_EXCLUDED = [
    "Notifications",
    "Power",
    "Speech",
    "Tailscale",
    "Voice",
    "Session/SessionManager.swift",
    "Session/SessionManager+Groups.swift",
    "Session/WebTab.swift",
    "Session/PersistedWebTab.swift",
    "SSH/PortForwardingManager.swift",
    "SSH/PortScanner.swift",
    "Terminal/GhosttyApp.swift",
    "Terminal/GhosttyBridge.swift",
    "Terminal/TerminalSurface.swift",
]

# Remote packages: (name, url, minimum version, products)
PACKAGES = [
    ("swift-nio-ssh", "https://github.com/apple/swift-nio-ssh.git", "0.9.0", ["NIOSSH"]),
    ("swift-nio", "https://github.com/apple/swift-nio.git", "2.62.0", ["NIOCore", "NIOPosix"]),
]
LOCAL_PACKAGES = [("RtachClient", ["RtachClient"])]

# Folder references copied into the app's resources, as in the iOS app.
RESOURCE_FOLDERS = ["Clauntty/Resources/rtach", "Clauntty/Resources/Themes"]

_ids = {}


def i(name):
    if name not in _ids:
        _ids[name] = "AC" + format(len(_ids) + 1, "022X")
    return _ids[name]


def excluded_files():
    core = os.path.join(ROOT, "Clauntty", "Core")
    out = []
    for entry in MAC_EXCLUDED:
        path = os.path.join(core, entry)
        if os.path.isdir(path):
            for dirpath, _, files in os.walk(path):
                for f in files:
                    out.append(os.path.relpath(os.path.join(dirpath, f), core))
        elif os.path.exists(path):
            out.append(entry)
        else:
            raise SystemExit(f"MAC_EXCLUDED entry doesn't exist: {entry}")
    return sorted(out)


def lines(items, indent):
    return "".join(f"{indent}{item},\n" for item in items)


def settings(d, indent="\t\t\t\t"):
    out = ""
    for key, value in d.items():
        if isinstance(value, list):
            out += f"{indent}{key} = (\n" + lines(value, indent + "\t") + f"{indent});\n"
        else:
            out += f"{indent}{key} = {value};\n"
    return out


def main():
    products = [p for _, _, _, ps in PACKAGES for p in ps] + [p for _, ps in LOCAL_PACKAGES for p in ps]
    resources = [os.path.basename(f) for f in RESOURCE_FOLDERS]

    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "SDKROOT": "macosx",
    }
    project_debug = {**project_common,
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ['"DEBUG=1"', '"$(inherited)"'],
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    }
    project_release = {**project_common,
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
    }
    target = {
        # Signed with the Apple Development identity, no provisioning profile:
        # the app uses no entitlements that need one.
        "CODE_SIGN_IDENTITY": '"Apple Development"',
        "CODE_SIGN_STYLE": "Manual",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "65533RB4LC",
        # No sandbox: it reads ~/.ssh/config and the keys it names.
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "NO",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Clauntty",
        "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.developer-tools"',
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/../Frameworks"'],
        "MARKETING_VERSION": "0.1",
        # Ghostty's static library needs libc++ and Carbon (keyboard layouts).
        "OTHER_LDFLAGS": ['"-lc++"', '"-framework"', "Carbon"],
        "PRODUCT_BUNDLE_IDENTIFIER": "com.octerm.clauntty.mac",
        "PRODUCT_NAME": "Clauntty",
        "PROVISIONING_PROFILE_SPECIFIER": '""',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
    }

    T = "\t\t"
    o = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n"

    o += "/* Begin PBXBuildFile section */\n"
    o += f'{T}{i("bf_ghostty")} /* GhosttyKit.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {i("fr_ghostty")} /* GhosttyKit.xcframework */; }};\n'
    for p in products:
        o += f'{T}{i("bf_" + p)} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {i("pd_" + p)} /* {p} */; }};\n'
    for r in resources:
        o += f'{T}{i("bf_res_" + r)} /* {r} in Resources */ = {{isa = PBXBuildFile; fileRef = {i("fr_res_" + r)} /* {r} */; }};\n'
    o += "/* End PBXBuildFile section */\n\n"

    o += "/* Begin PBXFileReference section */\n"
    o += f'{T}{i("fr_app")} /* Clauntty.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Clauntty.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
    o += f'{T}{i("fr_ghostty")} /* GhosttyKit.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = GhosttyKit.xcframework; path = Frameworks/GhosttyKit.xcframework; sourceTree = "<group>"; }};\n'
    for f, r in zip(RESOURCE_FOLDERS, resources):
        o += f'{T}{i("fr_res_" + r)} /* {r} */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = {r}; path = {f}; sourceTree = "<group>"; }};\n'
    o += "/* End PBXFileReference section */\n\n"

    o += "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */\n"
    o += f'{T}{i("ex_core")} /* Exceptions for "Clauntty/Core" folder in "ClaunttyMac" target */ = {{\n'
    o += f"{T}\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n{T}\tmembershipExceptions = (\n"
    o += lines(['"' + f + '"' for f in excluded_files()], T + "\t\t")
    o += f'{T}\t);\n{T}\ttarget = {i("t_mac")} /* ClaunttyMac */;\n{T}}};\n'
    o += "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */\n\n"

    o += "/* Begin PBXFileSystemSynchronizedRootGroup section */\n"
    o += f'{T}{i("sg_mac")} /* ClaunttyMac */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = ClaunttyMac; sourceTree = "<group>"; }};\n'
    o += f'{T}{i("sg_core")} /* Clauntty/Core */ = {{isa = PBXFileSystemSynchronizedRootGroup; exceptions = ({i("ex_core")} /* Exceptions for "Clauntty/Core" folder in "ClaunttyMac" target */, ); path = Clauntty/Core; sourceTree = "<group>"; }};\n'
    o += f'{T}{i("sg_models")} /* Clauntty/Models */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = Clauntty/Models; sourceTree = "<group>"; }};\n'
    o += "/* End PBXFileSystemSynchronizedRootGroup section */\n\n"

    o += "/* Begin PBXFrameworksBuildPhase section */\n"
    o += f'{T}{i("ph_frameworks")} /* Frameworks */ = {{\n{T}\tisa = PBXFrameworksBuildPhase;\n{T}\tbuildActionMask = 2147483647;\n{T}\tfiles = (\n'
    o += lines([f'{i("bf_ghostty")} /* GhosttyKit.xcframework in Frameworks */'] + [f'{i("bf_" + p)} /* {p} in Frameworks */' for p in products], T + "\t\t")
    o += f"{T}\t);\n{T}\trunOnlyForDeploymentPostprocessing = 0;\n{T}}};\n"
    o += "/* End PBXFrameworksBuildPhase section */\n\n"

    o += "/* Begin PBXGroup section */\n"
    o += f'{T}{i("g_main")} = {{\n{T}\tisa = PBXGroup;\n{T}\tchildren = (\n'
    o += lines([f'{i("sg_mac")} /* ClaunttyMac */', f'{i("g_shared")} /* Shared with iOS */',
                f'{i("g_frameworks")} /* Frameworks */', f'{i("g_products")} /* Products */'], T + "\t\t")
    o += f'{T}\t);\n{T}\tsourceTree = "<group>";\n{T}}};\n'
    o += f'{T}{i("g_shared")} /* Shared with iOS */ = {{\n{T}\tisa = PBXGroup;\n{T}\tchildren = (\n'
    o += lines([f'{i("sg_core")} /* Clauntty/Core */', f'{i("sg_models")} /* Clauntty/Models */']
               + [f'{i("fr_res_" + r)} /* {r} */' for r in resources], T + "\t\t")
    o += f'{T}\t);\n{T}\tname = "Shared with iOS";\n{T}\tsourceTree = "<group>";\n{T}}};\n'
    o += f'{T}{i("g_frameworks")} /* Frameworks */ = {{\n{T}\tisa = PBXGroup;\n{T}\tchildren = (\n'
    o += lines([f'{i("fr_ghostty")} /* GhosttyKit.xcframework */'], T + "\t\t")
    o += f'{T}\t);\n{T}\tname = Frameworks;\n{T}\tsourceTree = "<group>";\n{T}}};\n'
    o += f'{T}{i("g_products")} /* Products */ = {{\n{T}\tisa = PBXGroup;\n{T}\tchildren = (\n'
    o += lines([f'{i("fr_app")} /* Clauntty.app */'], T + "\t\t")
    o += f'{T}\t);\n{T}\tname = Products;\n{T}\tsourceTree = "<group>";\n{T}}};\n'
    o += "/* End PBXGroup section */\n\n"

    o += "/* Begin PBXNativeTarget section */\n"
    o += f'{T}{i("t_mac")} /* ClaunttyMac */ = {{\n{T}\tisa = PBXNativeTarget;\n'
    o += f'{T}\tbuildConfigurationList = {i("cl_target")} /* Build configuration list for PBXNativeTarget "ClaunttyMac" */;\n'
    o += f"{T}\tbuildPhases = (\n" + lines([f'{i("ph_sources")} /* Sources */', f'{i("ph_frameworks")} /* Frameworks */', f'{i("ph_resources")} /* Resources */'], T + "\t\t") + f"{T}\t);\n"
    o += f"{T}\tbuildRules = (\n{T}\t);\n{T}\tdependencies = (\n{T}\t);\n"
    o += f"{T}\tfileSystemSynchronizedGroups = (\n" + lines([f'{i("sg_mac")} /* ClaunttyMac */', f'{i("sg_core")} /* Clauntty/Core */', f'{i("sg_models")} /* Clauntty/Models */'], T + "\t\t") + f"{T}\t);\n"
    o += f"{T}\tname = ClaunttyMac;\n"
    o += f"{T}\tpackageProductDependencies = (\n" + lines([f'{i("pd_" + p)} /* {p} */' for p in products], T + "\t\t") + f"{T}\t);\n"
    o += f'{T}\tproductName = ClaunttyMac;\n{T}\tproductReference = {i("fr_app")} /* Clauntty.app */;\n'
    o += f'{T}\tproductType = "com.apple.product-type.application";\n{T}}};\n'
    o += "/* End PBXNativeTarget section */\n\n"

    o += "/* Begin PBXProject section */\n"
    o += f'{T}{i("project")} /* Project object */ = {{\n{T}\tisa = PBXProject;\n'
    o += f"{T}\tattributes = {{\n{T}\t\tBuildIndependentTargetsInParallel = 1;\n{T}\t\tLastSwiftUpdateCheck = 2700;\n{T}\t\tLastUpgradeCheck = 2700;\n{T}\t}};\n"
    o += f'{T}\tbuildConfigurationList = {i("cl_project")} /* Build configuration list for PBXProject "ClaunttyMac" */;\n'
    o += f"{T}\tdevelopmentRegion = en;\n{T}\thasScannedForEncodings = 0;\n{T}\tknownRegions = (\n{T}\t\ten,\n{T}\t\tBase,\n{T}\t);\n"
    o += f'{T}\tmainGroup = {i("g_main")};\n{T}\tminimizedProjectReferenceProxies = 1;\n'
    o += f"{T}\tpackageReferences = (\n"
    o += lines([f'{i("pk_" + n)} /* XCRemoteSwiftPackageReference "{n}" */' for n, _, _, _ in PACKAGES]
               + [f'{i("pk_" + n)} /* XCLocalSwiftPackageReference "{n}" */' for n, _ in LOCAL_PACKAGES], T + "\t\t")
    o += f"{T}\t);\n"
    o += f'{T}\tpreferredProjectObjectVersion = 77;\n{T}\tproductRefGroup = {i("g_products")} /* Products */;\n'
    o += f'{T}\tprojectDirPath = "";\n{T}\tprojectRoot = "";\n{T}\ttargets = (\n{T}\t\t{i("t_mac")} /* ClaunttyMac */,\n{T}\t);\n{T}}};\n'
    o += "/* End PBXProject section */\n\n"

    o += "/* Begin PBXResourcesBuildPhase section */\n"
    o += f'{T}{i("ph_resources")} /* Resources */ = {{\n{T}\tisa = PBXResourcesBuildPhase;\n{T}\tbuildActionMask = 2147483647;\n{T}\tfiles = (\n'
    o += lines([f'{i("bf_res_" + r)} /* {r} in Resources */' for r in resources], T + "\t\t")
    o += f"{T}\t);\n{T}\trunOnlyForDeploymentPostprocessing = 0;\n{T}}};\n"
    o += "/* End PBXResourcesBuildPhase section */\n\n"

    o += "/* Begin PBXSourcesBuildPhase section */\n"
    o += f'{T}{i("ph_sources")} /* Sources */ = {{\n{T}\tisa = PBXSourcesBuildPhase;\n{T}\tbuildActionMask = 2147483647;\n{T}\tfiles = (\n{T}\t);\n{T}\trunOnlyForDeploymentPostprocessing = 0;\n{T}}};\n'
    o += "/* End PBXSourcesBuildPhase section */\n\n"

    o += "/* Begin XCBuildConfiguration section */\n"
    for key, name, s in [("bc_project_debug", "Debug", project_debug), ("bc_project_release", "Release", project_release),
                         ("bc_target_debug", "Debug", target), ("bc_target_release", "Release", target)]:
        o += f'{T}{i(key)} /* {name} */ = {{\n{T}\tisa = XCBuildConfiguration;\n{T}\tbuildSettings = {{\n'
        o += settings(s) + f"{T}\t}};\n{T}\tname = {name};\n{T}}};\n"
    o += "/* End XCBuildConfiguration section */\n\n"

    o += "/* Begin XCConfigurationList section */\n"
    for key, what, debug, release in [("cl_project", 'PBXProject "ClaunttyMac"', "bc_project_debug", "bc_project_release"),
                                      ("cl_target", 'PBXNativeTarget "ClaunttyMac"', "bc_target_debug", "bc_target_release")]:
        o += f'{T}{i(key)} /* Build configuration list for {what} */ = {{\n{T}\tisa = XCConfigurationList;\n{T}\tbuildConfigurations = (\n'
        o += lines([f"{i(debug)} /* Debug */", f"{i(release)} /* Release */"], T + "\t\t")
        o += f"{T}\t);\n{T}\tdefaultConfigurationIsVisible = 0;\n{T}\tdefaultConfigurationName = Release;\n{T}}};\n"
    o += "/* End XCConfigurationList section */\n\n"

    o += "/* Begin XCLocalSwiftPackageReference section */\n"
    for n, _ in LOCAL_PACKAGES:
        o += f'{T}{i("pk_" + n)} /* XCLocalSwiftPackageReference "{n}" */ = {{\n{T}\tisa = XCLocalSwiftPackageReference;\n{T}\trelativePath = {n};\n{T}}};\n'
    o += "/* End XCLocalSwiftPackageReference section */\n\n"

    o += "/* Begin XCRemoteSwiftPackageReference section */\n"
    for n, url, version, _ in PACKAGES:
        o += f'{T}{i("pk_" + n)} /* XCRemoteSwiftPackageReference "{n}" */ = {{\n{T}\tisa = XCRemoteSwiftPackageReference;\n'
        o += f'{T}\trepositoryURL = "{url}";\n{T}\trequirement = {{\n{T}\t\tkind = upToNextMajorVersion;\n{T}\t\tminimumVersion = {version};\n{T}\t}};\n{T}}};\n'
    o += "/* End XCRemoteSwiftPackageReference section */\n\n"

    o += "/* Begin XCSwiftPackageProductDependency section */\n"
    for n, _, _, ps in PACKAGES:
        for p in ps:
            o += f'{T}{i("pd_" + p)} /* {p} */ = {{\n{T}\tisa = XCSwiftPackageProductDependency;\n{T}\tpackage = {i("pk_" + n)} /* XCRemoteSwiftPackageReference "{n}" */;\n{T}\tproductName = {p};\n{T}}};\n'
    for n, ps in LOCAL_PACKAGES:
        for p in ps:
            o += f'{T}{i("pd_" + p)} /* {p} */ = {{\n{T}\tisa = XCSwiftPackageProductDependency;\n{T}\tproductName = {p};\n{T}}};\n'
    o += "/* End XCSwiftPackageProductDependency section */\n"

    o += f'\t}};\n\trootObject = {i("project")} /* Project object */;\n}}\n'

    path = os.path.join(ROOT, "ClaunttyMac.xcodeproj", "project.pbxproj")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(o)
    print(f"Wrote {os.path.relpath(path, ROOT)} ({len(excluded_files())} iOS-only files excluded)")


if __name__ == "__main__":
    main()
