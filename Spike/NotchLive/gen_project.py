#!/usr/bin/env python3
"""Generates NotchLive.xcodeproj (an app plus a widget extension). No third-party tools needed."""
import os
from itertools import count
_n = count(1)
def uid(): return "%024X" % (0xA10000000000000000000000 + next(_n))

files = {  # path -> (type, name)
 "App/NotchLiveApp.swift": "sourcecode.swift", "Shared/NotchAttributes.swift": "sourcecode.swift",
 "Shared/Intents.swift": "sourcecode.swift", "Widget/NotchLiveWidget.swift": "sourcecode.swift",
 "App/Info.plist": "text.plist.xml", "Widget/Info.plist": "text.plist.xml",
 "App/App.entitlements": "text.plist.entitlements", "Widget/Widget.entitlements": "text.plist.entitlements",
}
ref = {p: uid() for p in files}
APP_P, EXT_P = uid(), uid()
build = {}  # (path, target) -> buildfile id
def bf(p, t): build[(p, t)] = uid(); return build[(p, t)]
app_srcs = ["App/NotchLiveApp.swift", "Shared/NotchAttributes.swift", "Shared/Intents.swift"]
ext_srcs = ["Widget/NotchLiveWidget.swift", "Shared/NotchAttributes.swift", "Shared/Intents.swift"]
app_bf = [bf(p, "app") for p in app_srcs]; ext_bf = [bf(p, "ext") for p in ext_srcs]
embed_bf = uid()
T_APP, T_EXT, PROJ = uid(), uid(), uid()
SRC_APP, SRC_EXT, RES_APP, RES_EXT, FW_APP, FW_EXT, EMB = (uid() for _ in range(7))
PROXY, DEP = uid(), uid()
G_ROOT, G_PROD, G_APP, G_SHARED, G_WIDGET = (uid() for _ in range(5))
CL_PROJ, CL_APP, CL_EXT = uid(), uid(), uid()
CFG = {k: uid() for k in ["pd", "pr", "ad", "ar", "ed", "er"]}

def q(s): return '"%s"' % s
def lst(ids): return "(" + ", ".join(ids) + ")"

common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "27.3", "SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Manual",
  "CODE_SIGN_IDENTITY": q("-"), "ENABLE_HARDENED_RUNTIME": "NO", "GENERATE_INFOPLIST_FILE": "NO", "ARCHS": "arm64",
  "ONLY_ACTIVE_ARCH": "YES", "CLANG_ENABLE_MODULES": "YES", "SWIFT_EMIT_LOC_STRINGS": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "NO"}
def settings(d): return "{\n" + "".join("\t\t\t\t%s = %s;\n" % (k, v) for k, v in sorted(d.items())) + "\t\t\t}"
app_s = {"PRODUCT_BUNDLE_IDENTIFIER": "dev.claudenotch.live", "PRODUCT_NAME": q("NotchLive"), "INFOPLIST_FILE": "App/Info.plist",
  "CODE_SIGN_ENTITLEMENTS": "App/App.entitlements", "LD_RUNPATH_SEARCH_PATHS": q("$(inherited) @executable_path/../Frameworks")}
ext_s = {"PRODUCT_BUNDLE_IDENTIFIER": "dev.claudenotch.live.widget", "PRODUCT_NAME": q("NotchLiveWidget"), "INFOPLIST_FILE": "Widget/Info.plist",
  "CODE_SIGN_ENTITLEMENTS": "Widget/Widget.entitlements", "SKIP_INSTALL": "YES",
  "LD_RUNPATH_SEARCH_PATHS": q("$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks")}

o = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n"]
def sect(name, body): o.append("\n/* Begin %s section */\n%s/* End %s section */\n" % (name, body, name))
sect("PBXBuildFile", "".join(
  "\t\t%s = {isa = PBXBuildFile; fileRef = %s; };\n" % (build[(p, t)], ref[p]) for (p, t) in build) +
  "\t\t%s = {isa = PBXBuildFile; fileRef = %s; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, CodeSignOnCopy, ); }; };\n" % (embed_bf, EXT_P))
sect("PBXContainerItemProxy", "\t\t%s = {isa = PBXContainerItemProxy; containerPortal = %s; proxyType = 1; remoteGlobalIDString = %s; remoteInfo = NotchLiveWidget; };\n" % (PROXY, PROJ, T_EXT))
sect("PBXCopyFilesBuildPhase", "\t\t%s = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = (%s, ); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0; };\n" % (EMB, embed_bf))
sect("PBXFileReference", "".join(
  "\t\t%s = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; };\n" % (ref[p], t, q(os.path.basename(p))) for p, t in files.items()) +
  "\t\t%s = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = NotchLive.app; sourceTree = BUILT_PRODUCTS_DIR; };\n" % APP_P +
  "\t\t%s = {isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = NotchLiveWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; };\n" % EXT_P)
sect("PBXFrameworksBuildPhase", "".join("\t\t%s = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };\n" % i for i in (FW_APP, FW_EXT)))
def grp(i, name, kids, path=None):
    return "\t\t%s = {isa = PBXGroup; children = (%s); %ssourceTree = \"<group>\"; };\n" % (i, ", ".join(kids), ("path = %s; " % path) if path else "") .replace("name", "name")
g = ""
g += "\t\t%s = {isa = PBXGroup; children = (%s, %s, %s, %s); sourceTree = \"<group>\"; };\n" % (G_ROOT, G_APP, G_SHARED, G_WIDGET, G_PROD)
g += "\t\t%s = {isa = PBXGroup; children = (%s, %s, %s); path = App; sourceTree = \"<group>\"; };\n" % (G_APP, ref["App/NotchLiveApp.swift"], ref["App/Info.plist"], ref["App/App.entitlements"])
g += "\t\t%s = {isa = PBXGroup; children = (%s, %s); path = Shared; sourceTree = \"<group>\"; };\n" % (G_SHARED, ref["Shared/NotchAttributes.swift"], ref["Shared/Intents.swift"])
g += "\t\t%s = {isa = PBXGroup; children = (%s, %s, %s); path = Widget; sourceTree = \"<group>\"; };\n" % (G_WIDGET, ref["Widget/NotchLiveWidget.swift"], ref["Widget/Info.plist"], ref["Widget/Widget.entitlements"])
g += "\t\t%s = {isa = PBXGroup; children = (%s, %s); name = Products; sourceTree = \"<group>\"; };\n" % (G_PROD, APP_P, EXT_P)
sect("PBXGroup", g)
sect("PBXNativeTarget",
  "\t\t%s = {isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = (%s, %s, %s, %s, ); buildRules = (); dependencies = (%s, ); name = NotchLive; productName = NotchLive; productReference = %s; productType = \"com.apple.product-type.application\"; };\n" % (T_APP, CL_APP, SRC_APP, FW_APP, RES_APP, EMB, DEP, APP_P) +
  "\t\t%s = {isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = (%s, %s, %s, ); buildRules = (); dependencies = (); name = NotchLiveWidget; productName = NotchLiveWidget; productReference = %s; productType = \"com.apple.product-type.app-extension\"; };\n" % (T_EXT, CL_EXT, SRC_EXT, FW_EXT, RES_EXT, EXT_P))
sect("PBXProject", "\t\t%s = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700; }; buildConfigurationList = %s; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = %s; productRefGroup = %s; projectDirPath = \"\"; projectRoot = \"\"; targets = (%s, %s, ); };\n" % (PROJ, CL_PROJ, G_ROOT, G_PROD, T_APP, T_EXT))
sect("PBXResourcesBuildPhase", "".join("\t\t%s = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };\n" % i for i in (RES_APP, RES_EXT)))
sect("PBXSourcesBuildPhase",
  "\t\t%s = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0; };\n" % (SRC_APP, lst(app_bf)) +
  "\t\t%s = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0; };\n" % (SRC_EXT, lst(ext_bf)))
sect("PBXTargetDependency", "\t\t%s = {isa = PBXTargetDependency; target = %s; targetProxy = %s; };\n" % (DEP, T_EXT, PROXY))
cfgs = ""
for key, name, s in [("pd", "Debug", {"DEBUG": "1"}), ("pr", "Release", {})]:
    cfgs += "\t\t%s = {isa = XCBuildConfiguration; buildSettings = %s; name = %s; };\n" % (CFG[key], settings({**common, **({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"} if s else {})}), name)
for key, name, base in [("ad", "Debug", app_s), ("ar", "Release", app_s), ("ed", "Debug", ext_s), ("er", "Release", ext_s)]:
    nm = "Debug" if key.endswith("d") else "Release"
    cfgs += "\t\t%s = {isa = XCBuildConfiguration; buildSettings = %s; name = %s; };\n" % (CFG[key], settings(base), nm)
sect("XCBuildConfiguration", cfgs)
sect("XCConfigurationList", "".join(
  "\t\t%s = {isa = XCConfigurationList; buildConfigurations = (%s, %s, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n" % (i, CFG[a], CFG[b])
  for i, a, b in [(CL_PROJ, "pd", "pr"), (CL_APP, "ad", "ar"), (CL_EXT, "ed", "er")]))
o.append("\t};\n\trootObject = %s;\n}\n" % PROJ)
os.makedirs("NotchLive.xcodeproj", exist_ok=True)
open("NotchLive.xcodeproj/project.pbxproj", "w").write("".join(o))
print("wrote NotchLive.xcodeproj")
