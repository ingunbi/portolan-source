#!/usr/bin/env python3
"""Writes ios/PortolanPad.xcodeproj: one iPad app target that compiles Sources/Portolan (minus the
mac-only files), depends on the PortolanCore package product (core/, in this repository) and
bundles assets/."""
import os, sys, re
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEAM = os.environ.get("PORTOLAN_TEAM", "")  # your Apple developer team id
BUNDLE = os.environ.get("PORTOLAN_BUNDLE", "app.portolan.ipad")
if not re.fullmatch(r"[A-Za-z0-9]*", TEAM):
    raise SystemExit("PORTOLAN_TEAM must contain only letters and digits")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", BUNDLE):
    raise SystemExit("PORTOLAN_BUNDLE must be a bundle identifier")
INCLUDE_PRIVATE_ASSETS = os.environ.get("PORTOLAN_BUNDLE_PRIVATE_ASSETS") == "1"
MAC_ONLY = []

def q(s): return '"%s"' % s
ids = {k: "A0000000000000000000%04X" % i for i, k in enumerate(
    "proj target group_main group_sources group_ios product srcphase fwphase respphase pkgref pkgdep pkgbuild cfg_proj_d cfg_proj_r cfg_tgt_d cfg_tgt_r cfglist_proj cfglist_tgt assets assetsbuild ios_group exc".split())}
exc = "".join('\t\t\t\t%s,\n' % q(f) for f in MAC_ONLY)
out = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{
/* Begin PBXBuildFile section */
		{ids['pkgbuild']} /* PortolanCore */ = {{isa = PBXBuildFile; productRef = {ids['pkgdep']} /* PortolanCore */; }};
		{ids['assetsbuild']} /* assets in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['assets']} /* assets */; }};
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
		{ids['product']} /* PortolanPad.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PortolanPad.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{ids['assets']} /* assets */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = assets; path = ../../core/assets; sourceTree = SOURCE_ROOT; }};
/* End PBXFileReference section */
/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		{ids['exc']} /* Exceptions for Sources/Portolan */ = {{
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
{exc}			);
			target = {ids['target']} /* PortolanPad */;
		}};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */
/* Begin PBXFileSystemSynchronizedRootGroup section */
		{ids['group_sources']} /* Portolan */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				{ids['exc']} /* Exceptions */,
			);
			name = Portolan;
			path = ../Sources/Portolan;
			sourceTree = SOURCE_ROOT;
		}};
		{ids['ios_group']} /* iOS */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			name = iOS;
			path = Sources;
			sourceTree = SOURCE_ROOT;
		}};
/* End PBXFileSystemSynchronizedRootGroup section */
/* Begin PBXFrameworksBuildPhase section */
		{ids['fwphase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids['pkgbuild']} /* PortolanCore */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */
/* Begin PBXGroup section */
		{ids['group_main']} = {{
			isa = PBXGroup;
			children = (
				{ids['group_sources']} /* Portolan */,
				{ids['ios_group']} /* iOS */,
				{ids['assets']} /* assets */,
				{ids['group_ios']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids['group_ios']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['product']} /* PortolanPad.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
		{ids['target']} /* PortolanPad */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['cfglist_tgt']};
			buildPhases = (
				{ids['srcphase']} /* Sources */,
				{ids['fwphase']} /* Frameworks */,
				{ids['respphase']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{ids['group_sources']} /* Portolan */,
				{ids['ios_group']} /* iOS */,
			);
			name = PortolanPad;
			packageProductDependencies = (
				{ids['pkgdep']} /* PortolanCore */,
			);
			productName = PortolanPad;
			productReference = {ids['product']} /* PortolanPad.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */
/* Begin PBXProject section */
		{ids['proj']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {{
					{ids['target']} = {{
						CreatedOnToolsVersion = 27.0;
					}};
				}};
			}};
			buildConfigurationList = {ids['cfglist_proj']};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = ko;
			hasScannedForEncodings = 0;
			knownRegions = (
				ko,
				en,
				Base,
			);
			mainGroup = {ids['group_main']};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{ids['pkgref']} /* XCLocalSwiftPackageReference "../../core" */,
			);
			productRefGroup = {ids['group_ios']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* PortolanPad */,
			);
		}};
/* End PBXProject section */
/* Begin PBXResourcesBuildPhase section */
		{ids['respphase']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids['assetsbuild']} /* assets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */
/* Begin PBXSourcesBuildPhase section */
		{ids['srcphase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */
/* Begin XCBuildConfiguration section */
		{ids['cfg_proj_d']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				ENABLE_TESTABILITY = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 2;
			}};
			name = Debug;
		}};
		{ids['cfg_proj_r']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 2;
			}};
			name = Release;
		}};
		{ids['cfg_tgt_d']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "{TEAM}";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "Portolan";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UIRequiresFullScreen = NO;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				MARKETING_VERSION = 0.3.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE};
				PRODUCT_NAME = PortolanPad;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
			}};
			name = Debug;
		}};
		{ids['cfg_tgt_r']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "{TEAM}";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "Portolan";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UIRequiresFullScreen = NO;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				MARKETING_VERSION = 0.3.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE};
				PRODUCT_NAME = PortolanPad;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */
/* Begin XCConfigurationList section */
		{ids['cfglist_proj']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['cfg_proj_d']} /* Debug */,
				{ids['cfg_proj_r']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['cfglist_tgt']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['cfg_tgt_d']} /* Debug */,
				{ids['cfg_tgt_r']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
/* Begin XCLocalSwiftPackageReference section */
		{ids['pkgref']} /* XCLocalSwiftPackageReference "../../core" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = "../../core";
		}};
/* End XCLocalSwiftPackageReference section */
/* Begin XCSwiftPackageProductDependency section */
		{ids['pkgdep']} /* PortolanCore */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {ids['pkgref']} /* XCLocalSwiftPackageReference "../../core" */;
			productName = PortolanCore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {ids['proj']} /* Project object */;
}}
"""
if not INCLUDE_PRIVATE_ASSETS:
    # Remove every resource reference by default; only source code enters the app.
    out = "\n".join(line for line in out.splitlines() if ids["assets"] not in line and ids["assetsbuild"] not in line) + "\n"
proj = os.path.join(ROOT, "ios", "PortolanPad.xcodeproj")
os.makedirs(proj, exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w").write(out)
print("wrote", proj)
