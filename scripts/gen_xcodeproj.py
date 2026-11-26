#!/usr/bin/env python3
"""Generates ClaudeNotch.xcodeproj (no third-party tools). Run from anywhere; writes next to Package.swift.

Targets: ClaudeNotchCore (static lib, the same sources SwiftPM tests), claude-notch-hook (tool),
ClaudeNotch (app, embeds the widget extension and the hook), ClaudeNotchWidget (Live Activity UI).
The signing team comes from $CLAUDE_NOTCH_TEAM or .xcode-team (not committed), so no personal ID lives in the repo.
"""
import glob, os
from itertools import count

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
version = open("VERSION").read().strip()
team = os.environ.get("CLAUDE_NOTCH_TEAM") or (open(".xcode-team").read().strip() if os.path.exists(".xcode-team") else "")

_n = count(1)
def uid(): return "%024X" % (0xB20000000000000000000000 + next(_n))
def q(s): return '"%s"' % s

def swift_files(*patterns):
    out = []
    for p in patterns: out += sorted(glob.glob(p))
    return out

CORE = swift_files("Sources/ClaudeNotchCore/*.swift")
HOOK = swift_files("Sources/claude-notch-hook/*.swift")
APP = swift_files("App/*.swift")
SHARED = swift_files("Shared/*.swift")
WIDGET = swift_files("Widget/*.swift")
OTHER = {"App/Info.plist": "text.plist.xml", "App/App.entitlements": "text.plist.entitlements",
         "Widget/Info.plist": "text.plist.xml", "Widget/Widget.entitlements": "text.plist.entitlements"}

ref = {}
def fref(path):
    if path not in ref: ref[path] = uid()
    return ref[path]
for f in CORE + HOOK + APP + SHARED + WIDGET + list(OTHER): fref(f)

targets = {}
def target(name, product, ptype, srcs, prodref_type, prodname):
    t = dict(name=name, id=uid(), srcs=srcs, product=uid(), ptype=ptype, prodname=prodname, ptype_ref=prodref_type,
             cl=uid(), dbg=uid(), rel=uid(), sphase=uid(), fphase=uid(), rphase=uid(), deps=[], links=[], copies=[])
    targets[name] = t
    return t

core = target("ClaudeNotchCore", None, "com.apple.product-type.library.static", CORE, "archive.ar", "libClaudeNotchCore.a")
hook = target("claude-notch-hook", None, "com.apple.product-type.tool", HOOK, "compiled.mach-o.executable", "claude-notch-hook")
widget = target("ClaudeNotchWidget", None, "com.apple.product-type.app-extension", WIDGET + SHARED, "wrapper.app-extension", "ClaudeNotchWidget.appex")
app = target("ClaudeNotch", None, "com.apple.product-type.application", APP + SHARED, "wrapper.application", "ClaudeNotch.app")

PROJ, G_ROOT, G_PROD, CL_PROJ, PD, PR = uid(), uid(), uid(), uid(), uid(), uid()

bfs = []  # (id, line)
def buildfile(fileref, settings=None):
    i = uid()
    s = " settings = {%s };" % settings if settings else ""
    bfs.append("\t\t%s = {isa = PBXBuildFile; fileRef = %s;%s };\n" % (i, fileref, s))
    return i

for t in targets.values():
    t["src_bf"] = [buildfile(ref[f]) for f in t["srcs"]]
for t in (hook, widget, app):
    t["link_bf"] = [buildfile(core["product"])]
embed_ext = buildfile(widget["product"], "ATTRIBUTES = (RemoveHeadersOnCopy, CodeSignOnCopy, );")
copy_hook = buildfile(hook["product"], "ATTRIBUTES = (CodeSignOnCopy, );")

proxies, tdeps = [], []
def depend(t, on):
    p, d = uid(), uid()
    proxies.append("\t\t%s = {isa = PBXContainerItemProxy; containerPortal = %s; proxyType = 1; remoteGlobalIDString = %s; remoteInfo = %s; };\n" % (p, PROJ, on["id"], on["name"]))
    tdeps.append("\t\t%s = {isa = PBXTargetDependency; target = %s; targetProxy = %s; };\n" % (d, on["id"], p))
    t["deps"].append(d)
for t in (hook, widget, app): depend(t, core)
depend(app, widget); depend(app, hook)
EMB, CPH = uid(), uid()

def settings(d): return "{\n" + "".join("\t\t\t\t%s = %s;\n" % (k, v) for k, v in sorted(d.items())) + "\t\t\t}"
common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "27.3", "SWIFT_VERSION": "6.0", "ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "YES",
          "CLANG_ENABLE_MODULES": "YES", "SWIFT_EMIT_LOC_STRINGS": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
          "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": "1",
          "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": q("Apple Development"), "ENABLE_HARDENED_RUNTIME": "NO"}
if team: common["DEVELOPMENT_TEAM"] = team
tset = {
 "ClaudeNotchCore": {"PRODUCT_NAME": "ClaudeNotchCore", "DEFINES_MODULE": "YES", "SKIP_INSTALL": "YES", "CODE_SIGNING_ALLOWED": "NO"},
 "claude-notch-hook": {"PRODUCT_NAME": q("claude-notch-hook"), "SKIP_INSTALL": "YES", "CODE_SIGN_IDENTITY": q("-"), "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": q("")},
 "ClaudeNotchWidget": {"PRODUCT_NAME": "ClaudeNotchWidget", "PRODUCT_BUNDLE_IDENTIFIER": "dev.claudenotch.app.widget", "INFOPLIST_FILE": "Widget/Info.plist",
   "CODE_SIGN_ENTITLEMENTS": "Widget/Widget.entitlements", "SKIP_INSTALL": "YES", "SWIFT_VERSION": "5.0",
   "LD_RUNPATH_SEARCH_PATHS": q("$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks")},
 "ClaudeNotch": {"SWIFT_VERSION": "5.0", "PRODUCT_NAME": "ClaudeNotch", "PRODUCT_BUNDLE_IDENTIFIER": "dev.claudenotch.app", "INFOPLIST_FILE": "App/Info.plist",
   "CODE_SIGN_ENTITLEMENTS": "App/App.entitlements", "LD_RUNPATH_SEARCH_PATHS": q("$(inherited) @executable_path/../Frameworks")},
}

o = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n"]
def sect(name, body): o.append("\n/* Begin %s section */\n%s/* End %s section */\n" % (name, body, name))
sect("PBXBuildFile", "".join(bfs))
sect("PBXContainerItemProxy", "".join(proxies))
sect("PBXCopyFilesBuildPhase",
  "\t\t%s = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = (%s, ); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0; };\n" % (EMB, embed_ext) +
  "\t\t%s = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 6; files = (%s, ); name = \"Copy hook forwarder\"; runOnlyForDeploymentPostprocessing = 0; };\n" % (CPH, copy_hook))
fr = ""
for f, i in ref.items():
    t = OTHER.get(f, "sourcecode.swift")
    fr += "\t\t%s = {isa = PBXFileReference; lastKnownFileType = %s; name = %s; path = %s; sourceTree = SOURCE_ROOT; };\n" % (i, t, q(os.path.basename(f)), q(f))
for t in targets.values():
    fr += "\t\t%s = {isa = PBXFileReference; explicitFileType = %s; includeInIndex = 0; path = %s; sourceTree = BUILT_PRODUCTS_DIR; };\n" % (t["product"], q(t["ptype_ref"]), q(t["prodname"]))
sect("PBXFileReference", fr)
sect("PBXFrameworksBuildPhase", "".join(
  "\t\t%s = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (%s); runOnlyForDeploymentPostprocessing = 0; };\n" % (t["fphase"], ", ".join(t.get("link_bf", [])) + (", " if t.get("link_bf") else ""))
  for t in targets.values()))
allfiles = list(ref)
sect("PBXGroup",
  "\t\t%s = {isa = PBXGroup; children = (%s, ); sourceTree = \"<group>\"; };\n" % (G_ROOT, ", ".join([ref[f] for f in allfiles] + [G_PROD])) +
  "\t\t%s = {isa = PBXGroup; children = (%s, ); name = Products; sourceTree = \"<group>\"; };\n" % (G_PROD, ", ".join(t["product"] for t in targets.values())))
nt = ""
for t in targets.values():
    phases = [t["sphase"], t["fphase"], t["rphase"]]
    if t is app: phases += [EMB, CPH]
    nt += "\t\t%s = {isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = (%s, ); buildRules = (); dependencies = (%s); name = %s; productName = %s; productReference = %s; productType = %s; };\n" % (
      t["id"], t["cl"], ", ".join(phases), "".join(d + ", " for d in t["deps"]), q(t["name"]), q(t["name"]), t["product"], q(t["ptype"]))
sect("PBXNativeTarget", nt)
sect("PBXProject", "\t\t%s = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700; }; buildConfigurationList = %s; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = %s; productRefGroup = %s; projectDirPath = \"\"; projectRoot = \"\"; targets = (%s, ); };\n" % (PROJ, CL_PROJ, G_ROOT, G_PROD, ", ".join(t["id"] for t in targets.values())))
sect("PBXResourcesBuildPhase", "".join("\t\t%s = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };\n" % t["rphase"] for t in targets.values()))
sect("PBXSourcesBuildPhase", "".join(
  "\t\t%s = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (%s); runOnlyForDeploymentPostprocessing = 0; };\n" % (t["sphase"], "".join(b + ", " for b in t["src_bf"])) for t in targets.values()))
sect("PBXTargetDependency", "".join(tdeps))
cfgs = ""
for name, cid in (("Debug", PD), ("Release", PR)):
    extra = {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"} if name == "Debug" else {}
    cfgs += "\t\t%s = {isa = XCBuildConfiguration; buildSettings = %s; name = %s; };\n" % (cid, settings({**common, **extra}), name)
for t in targets.values():
    cfgs += "\t\t%s = {isa = XCBuildConfiguration; buildSettings = %s; name = Debug; };\n" % (t["dbg"], settings(tset[t["name"]]))
    cfgs += "\t\t%s = {isa = XCBuildConfiguration; buildSettings = %s; name = Release; };\n" % (t["rel"], settings(tset[t["name"]]))
sect("XCBuildConfiguration", cfgs)
cl = "\t\t%s = {isa = XCConfigurationList; buildConfigurations = (%s, %s, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n" % (CL_PROJ, PD, PR)
for t in targets.values():
    cl += "\t\t%s = {isa = XCConfigurationList; buildConfigurations = (%s, %s, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };\n" % (t["cl"], t["dbg"], t["rel"])
sect("XCConfigurationList", cl)
o.append("\t};\n\trootObject = %s;\n}\n" % PROJ)
os.makedirs("ClaudeNotch.xcodeproj", exist_ok=True)
open("ClaudeNotch.xcodeproj/project.pbxproj", "w").write("".join(o))
print("wrote ClaudeNotch.xcodeproj" + ("" if team else "  (no team: set CLAUDE_NOTCH_TEAM or .xcode-team)"))
