# Portolan

**A Swift engine for a classic sailing-and-trade RPG, with macOS, iPad and Android tablet clients.**

항해·교역·도시·함대·전투·이벤트·저장을 구현하는 비공식 연구 프로젝트입니다. 새 엔진 코드와 도구는 **MIT**로 공개합니다.

> **원작 데이터는 포함하지 않습니다.** 실행에는 사용자가 보유한 한글 DOS판 《대항해시대 II / Uncharted Waters: New Horizons》 자료가 필요합니다. 이 프로젝트는 원작 권리자와 관련 없는 비공식 프로젝트이며, 원작 콘텐츠의 권리를 부여하지 않습니다.

[License](LICENSE) · [Notice](NOTICE.md) · [Third-party components](THIRD_PARTY_NOTICES.md) · [Contributing](CONTRIBUTING.md)

## Source layout

| 경로 | 내용 |
| --- | --- |
| `core/` | 공통 Swift 규칙·상태 엔진, JSON-lines 실행기, 자료 해석 도구와 연구 문서 |
| `macos/` | SwiftUI·Metal Mac 앱 |
| `ipad/` | SwiftUI iPad 앱과 Xcode 프로젝트 생성기 |
| `android/` | Jetpack Compose 태블릿 화면과 Swift 엔진 빌드 스크립트 |
| `docs/` | 공개 범위, 플랫폼·휴대폰 확장 계획 |

휴대폰 전용 화면은 아직 구현되지 않았습니다. iPhone·Android phone 계획 문서는 `docs/`에 있으며 지원 완료로 표시하지 않습니다.

## Build the engine without game data

Swift 5.9 이상과 호환 플랫폼 도구가 필요합니다.

```sh
cd core
swift build
swift test
```

원작 자료가 없는 경우 자료 의존 검사는 **skipped**로 표시합니다. 이 결과를 원작 복원 완성이나 전체 게임 플레이 검증으로 해석하지 않습니다. 테스트는 원작 파일을 다운로드하지 않습니다.

## Run with your own data

원본과 추출 결과는 `core/original/`, `core/assets/`에만 보관하며 Git에서 제외합니다.

```sh
# 저장소 루트에서, 본인이 보유한 원본의 GAME 폴더를 복사합니다.
mkdir -p core/original
cp -R /path/to/your/GAME core/original/GAME
python3 -m venv core/.venv
core/.venv/bin/pip install capstone numpy scipy
PYTHON=.venv/bin/python sh core/tools/build_assets.sh
```

외부 파일은 읽기만 하며 원작 실행 파일을 실행하지 않습니다. 음악 변환에는 macOS의 `afconvert`가 필요합니다. 선택 도구와 모델이 아닌 일반 Python 의존성은 각 배포자의 라이선스를 따릅니다.

### macOS

```sh
sh macos/scripts/build_app.sh  # 원작 데이터 없는 앱 번들
PORTOLAN_ASSETS="$PWD/core/assets" macos/build/Portolan.app/Contents/MacOS/Portolan
```

SwiftUI 매크로가 없는 최신 CLT SDK에서는 전체 Xcode 또는 설치된 호환 SDK가 필요할 수 있습니다. SDK를 직접 고르려면 `PORTOLAN_SDK_PATH=/path/to/MacOSX.sdk sh macos/scripts/build_app.sh`를 사용합니다.

### iPad

```sh
python3 ipad/ios/make_project.py  # 기본값: 원작 데이터 리소스 제외
```

생성된 프로젝트를 전체 Xcode에서 엽니다. 실기기 서명은 본인 `PORTOLAN_TEAM`·`PORTOLAN_BUNDLE`로 설정하며 Git에 저장하지 않습니다. 현재 앱 내 데이터 가져오기는 구현되지 않아 플레이하려는 개인용 기기 빌드에는 아래의 명시적 자료 포함 옵션이 필요합니다.

### Android tablet

Android SDK·JDK 17·Gradle과 Android용 Swift toolchain·NDK가 별도로 필요합니다. 기존 코드 기준은 compileSdk 35, minSdk 26, Swift 6.4.2, NDK r30이며 도구 경로는 `SWIFT`·`ANDROID_NDK_HOME`·`PORTOLAN_CORE`로 지정합니다.

```sh
cd android
sh build_engine.sh
gradle assembleDebug   # 기본값: 원작 데이터 제외
```

Gradle wrapper와 도구 바이너리는 이 저장소에 포함하지 않습니다. Android 엔진은 arm64 전용이며 앱 내 자료 가져오기는 아직 없습니다.

## Private builds with game data

다음 옵션은 **본인 사용을 위한 개인용 빌드**에만 사용합니다. 결과 앱·APK에는 원작 자료가 들어가므로 공개 저장소·릴리스에 올리지 마세요.

```sh
PORTOLAN_BUNDLE_PRIVATE_ASSETS=1 sh macos/scripts/build_app.sh
PORTOLAN_BUNDLE_PRIVATE_ASSETS=1 python3 ipad/ios/make_project.py
# android/에서:
gradle -PbundlePrivateAssets=true assembleDebug
```

운영 설정·기기 서명·실제 세이브·추출물·검사 화면은 별도로 보관합니다. 공개 소스의 파일 범위 검사는 `python3 tools/audit_public_source.py`로 실행합니다.
