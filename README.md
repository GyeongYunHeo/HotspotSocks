# HotspotSocks

HotspotSocks는 iPhone의 개인용 핫스팟에 연결된 다른 기기가 iPhone을 SOCKS5 또는 선택형 HTTP 프록시로 사용할 수 있는지 검증하는 네이티브 iOS 앱입니다. SwiftUI와 Network.framework만 사용하며, 비공개 API나 오디오·위치 기반의 백그라운드 유지 기법은 사용하지 않습니다.

현재 앱 버전은 **1.0.0**입니다.

> 이 프로젝트는 네트워크 실험 및 개인 사용을 목적으로 합니다. iOS는 일반적인 상시 실행 서버 환경이 아니므로 장시간 백그라운드 동작이나 모든 iOS 버전에서의 핫스팟 수신을 보장하지 않습니다.

## 주요 기능

- SOCKS5 `NO AUTH` 및 TCP `CONNECT`
- SOCKS5 `UDP ASSOCIATE` 기반 UDP 릴레이
- 선택형 HTTP 프록시
  - 일반 HTTP 전달
  - HTTPS `CONNECT` 터널
- `wpad.dat`/PAC 파일 제공
- 자동, 시스템 기본, 셀룰러 전용 송신 경로 선택
- 셀룰러 전용 모드의 무음 우회 방지
- 사설·루프백·링크 로컬·멀티캐스트 목적지 접근 정책
- 연결 수, 송수신량, 거부 횟수 등 실시간 통계
- 최대 동시 연결 기본값 128 및 빠른 프리셋 선택
- 한국어 중심의 SwiftUI 화면, 다크 모드, Dynamic Type, VoiceOver 대응
- 유한한 사용자 시작 작업으로서의 백그라운드 지속 처리 실험

## 동작 구조

```text
핫스팟 연결 기기
   ├─ SOCKS5 :9876 ─ TCP CONNECT ─ 인터넷
   │                 └ UDP ASSOCIATE ─ 인터넷
   │
   └─ HTTP :9877 ─── 일반 HTTP 전달 ─ 인터넷
                     ├ HTTPS CONNECT ─ 인터넷
                     └ /wpad.dat ─ PAC 파일 제공
```

SOCKS5와 HTTP는 별도의 리스너를 사용하지만 연결 제한, 송신 경로, 접근 정책, 통계 및 중지 처리는 공유합니다. HTTP 프록시는 기본적으로 꺼져 있으며 SOCKS5가 주 전송 방식입니다.

## 개발 환경

- Xcode 26 이상
- iOS 26.0 이상
- 개인용 핫스팟 수신 검증을 위한 실제 iPhone
- 실제 기기 설치 시 사용할 Apple Developer Team

## 프로젝트 설정

저장소에는 개인 Apple Team ID와 개인 번들 식별자가 포함되지 않습니다. 다음 절차로 로컬 전용 설정을 만드세요.

1. `Config/Local.xcconfig.example`을 `Config/Local.xcconfig`로 복사합니다.
2. `HOTSPOTSOCKS_BUNDLE_IDENTIFIER`를 본인이 소유한 고유한 역도메인 형식으로 바꿉니다.
3. `HOTSPOTSOCKS_DEVELOPMENT_TEAM`에 본인의 Apple Team ID를 입력합니다.
4. `HotspotSocks.xcodeproj`를 열고 `HotspotSocks` 스킴을 실제 iPhone에서 빌드합니다.
5. 앱이 요청하면 로컬 네트워크 접근을 허용합니다.

예시:

```xcconfig
HOTSPOTSOCKS_BUNDLE_IDENTIFIER = com.example.HotspotSocks
HOTSPOTSOCKS_DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

`Config/Local.xcconfig`는 `.gitignore`에 포함되어 GitHub에 올라가지 않습니다. 토큰이나 비밀번호가 추가로 필요해지는 경우에는 `.env` 같은 로컬 전용 파일을 사용하고, 공개 저장소에는 값이 비어 있는 예시 파일만 추가하세요.

## 사용 방법

### SideStore로 설치

Apple Team ID와 개인 번들 ID가 저장소에 없어도 SideStore용 IPA를 만들 수 있습니다. 이 IPA가 서명 없이 그대로 실행되는 것은 아니며, SideStore가 설치 과정에서 사용자의 Apple 계정으로 다시 서명하고 프로비저닝한 뒤 iPhone에 설치합니다.

Swift 소스를 변경할 필요는 없습니다. 공개 기본값인 `com.example.HotspotSocks` 대신 충돌 가능성이 낮은 번들 ID를 빌드 명령에서만 지정할 수 있습니다.

```sh
xcodebuild \
  -project HotspotSocks.xcodeproj \
  -scheme HotspotSocks \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedDataUnsigned \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  HOTSPOTSOCKS_BUNDLE_IDENTIFIER=io.github.YOUR_GITHUB_ID.HotspotSocks \
  HOTSPOTSOCKS_DEVELOPMENT_TEAM= \
  build
```

`build-for-testing` 결과가 아니라 위의 일반 Release 빌드 결과를 사용하세요. 생성된 앱을 표준 IPA 구조로 포장합니다.

```sh
IPA_TEMP_DIR="$(mktemp -d)"
mkdir -p "$IPA_TEMP_DIR/Payload"
cp -R \
  DerivedDataUnsigned/Build/Products/Release-iphoneos/HotspotSocks.app \
  "$IPA_TEMP_DIR/Payload/HotspotSocks.app"
ditto -c -k --sequesterRsrc --keepParent \
  "$IPA_TEMP_DIR/Payload" \
  HotspotSocks-unsigned.ipa
```

완성된 `HotspotSocks-unsigned.ipa`를 SideStore로 가져와 설치합니다.

설치 조건과 주의사항:

- HotspotSocks의 최소 지원 버전이 iOS 26.0이므로 대상 iPhone도 iOS 26 이상이어야 합니다.
- SideStore에 Apple 계정으로 로그인하고 iPhone의 개발자 모드와 개발자 앱 신뢰를 활성화해야 합니다.
- 설치·업데이트·갱신할 때 Wi-Fi와 LocalDevVPN 연결이 필요합니다.
- 무료 Apple 개발 계정으로 서명한 앱은 일반적으로 7일마다 SideStore에서 갱신해야 합니다.
- iOS 26.4 이상에서는 SideStore 버전에 따라 최신 nightly가 필요할 수 있으므로 공식 문제 해결 문서를 확인하세요.
- 번들 ID가 이미 등록되었다는 오류가 발생하면 `YOUR_GITHUB_ID` 부분을 포함해 더 고유한 빌드용 번들 ID로 다시 생성하세요. 이는 빌드 인자 변경이므로 저장소의 Swift 소스를 수정하지 않습니다.

[SideStore 설치 안내](https://docs.sidestore.io/docs/installation/install)와 [필수 조건](https://docs.sidestore.io/docs/installation/prerequisites), [오류 안내](https://docs.sidestore.io/docs/troubleshooting/error-codes)를 함께 확인하세요.

SideStore가 재서명하면서 최종 번들 ID를 변경할 경우, 번들 ID를 기반으로 하는 `BGContinuedProcessingTask` 허용 식별자와 런타임 식별자가 달라질 수 있습니다. 앱 설치 및 포그라운드 프록시 동작과는 별개이지만 백그라운드 지속 처리 등록이 실패할 가능성이 있으므로 최초 SideStore 설치 후 따로 검증해야 합니다. 현재 SideStore 설치 경로는 아직 실제 기기 합격 항목으로 기록되지 않았습니다.

### SOCKS5

1. iPhone에서 개인용 핫스팟을 켜고 클라이언트 기기를 연결합니다.
2. HotspotSocks에서 **프록시 시작**을 누릅니다.
3. 상태가 **연결 준비됨**으로 바뀌면 화면에 표시된 주소와 포트를 확인합니다.
4. 클라이언트 앱에 SOCKS5, 표시된 호스트, 기본 포트 `9876`, 인증 없음으로 설정합니다.

핫스팟 주소를 항상 `172.20.10.1`이라고 가정하지 마세요. 앱이 실제 인터페이스에서 감지한 주소와 클라이언트의 게이트웨이 정보를 비교해야 합니다.

개발 장비에서 해당 핫스팟 경로에 접근할 수 있다면 다음과 같이 확인할 수 있습니다.

```sh
curl --socks5-hostname <iPhone 주소>:9876 --head https://example.com/
```

### HTTP 및 PAC

1. 앱의 **고급 설정 및 진단 → HTTP 프록시(선택 사항)**를 켭니다.
2. 수동 HTTP 프록시는 표시된 iPhone 주소와 기본 포트 `9877`로 설정합니다.
3. PAC를 지원하는 클라이언트에는 앱이 표시하는 다음 형식의 URL을 입력합니다.

```text
http://<iPhone 주소>:9877/wpad.dat
```

수동 HTTP 프록시 확인 예시:

```sh
curl -x http://<iPhone 주소>:9877 --head http://example.com/
curl -x http://<iPhone 주소>:9877 --head https://example.com/
```

현재 기능은 **PAC URL을 수동으로 입력하는 방식**입니다. DHCP 옵션 252 또는 DNS의 `wpad` 호스트를 이용한 무설정 자동 WPAD 탐색은 구현했다고 주장하지 않습니다. 생성되는 PAC에는 `DIRECT` 우회가 없으며 HTTP 프록시만 안내합니다.

## 보안 주의사항

- 프록시 인증을 구현하지 않았으므로 신뢰할 수 있는 개인용 핫스팟 환경에서만 사용하세요.
- 인터넷에 직접 노출하거나 공용 네트워크의 범용 프록시로 운영하지 마세요.
- 기본 설정에서는 사설망, 링크 로컬, 루프백, 미지정 및 멀티캐스트 목적지를 차단합니다.
- **로컬 네트워크 접근**은 신뢰하는 LAN 대상을 의도적으로 시험할 때만 켜세요. 루프백, 미지정 및 멀티캐스트 목적지는 이 설정과 관계없이 차단됩니다.
- HTTP 프록시는 TLS를 가로채지 않으며 인증서 설치도 요구하지 않습니다. HTTPS는 `CONNECT` 터널로 전달합니다.

## 지원 범위

| 기능 | 상태 |
| --- | --- |
| SOCKS5 `NO AUTH` | 지원 |
| SOCKS5 TCP `CONNECT` | 실제 기기 핵심 경로 통과 |
| SOCKS5 `UDP ASSOCIATE` | 실제 기기 핵심 경로 통과 |
| SOCKS5 `BIND` | 미지원 |
| 분할된 SOCKS5 UDP 조각(`FRAG != 0`) | 미지원, 안전하게 폐기 |
| HTTP 전달 | 실제 기기 핵심 경로 통과 |
| HTTPS `CONNECT` | 실제 기기 핵심 경로 통과 |
| `wpad.dat`/PAC 생성 및 제공 | 구현 및 빌드 통과 |
| PAC 통합 실제 기기 검증 | 진행 예정 |
| 자동 DHCP/DNS WPAD 탐색 | 미지원 |

Phase 12의 HTTP 핵심 테스트 1–3은 실제 기기에서 통과했습니다. PAC 구현과 네이티브 응답 검증은 통과했지만, PAC 클라이언트 적용·보안 정책·셀룰러 전용 동작·동시 사용을 포함한 통합 실제 기기 검증은 아직 남아 있습니다. 상세한 근거와 재현 절차는 [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md)를 확인하세요.

## 빌드 및 테스트

서명 없이 일반 iOS 기기 대상 컴파일을 확인하려면 다음 명령을 사용할 수 있습니다.

```sh
xcodebuild \
  -project HotspotSocks.xcodeproj \
  -scheme HotspotSocks \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

이 명령은 컴파일을 확인하지만 개인용 핫스팟, 셀룰러 송신 경로 및 백그라운드 동작에 대한 실제 기기 검증을 대체하지 않습니다. 테스트 보조 도구는 `Tools/`에 있으며, 단계별 명령과 합격 기준은 개발 상태 문서에 기록되어 있습니다.

## 저장소 구성

```text
HotspotSocks/          앱 화면과 프록시 구현
HotspotSocksTests/     파서·정책·설정·통계 단위 테스트
Config/                공개 기본값과 로컬 설정 예시
Tools/                 실제 기기 검증용 보조 스크립트
DEVELOPMENT_STATUS.md  단계별 구현·검증 기록
BACKGROUND_TEST_RESULTS.md  백그라운드 테스트 결과
CHANGELOG.md           버전별 변경 이력
```

## 알려진 제한사항

- 개인용 핫스팟을 통한 수신 가능 여부는 iOS 버전과 기기 환경에 따라 달라질 수 있습니다.
- 기본 30분 백그라운드 검증은 통과했지만 장시간 잠금, 저전력 모드, 발열 및 운영체제 만료 동작은 추가 검증 대상입니다.
- `BGContinuedProcessingTask`는 유한한 사용자 시작 작업을 위한 실험이며 데몬이나 가동 시간 보장이 아닙니다.
- 임의의 Android UDP를 투명하게 전달하지 않습니다. 클라이언트가 SOCKS5 UDP ASSOCIATE를 직접 지원해야 합니다.
- HTTP 프록시 인증, TLS 가로채기, 투명 프록시, HTTP/2 프록시 프로토콜은 지원하지 않습니다.

## 버전 관리

이 프로젝트는 [Semantic Versioning](https://semver.org/lang/ko/) 형식의 버전을 사용하며, 지금까지 구현된 기능을 첫 기준 버전 `1.0.0`으로 관리합니다. 변경 사항은 [CHANGELOG.md](CHANGELOG.md)에 기록합니다.

## 라이선스

현재 별도의 오픈 소스 라이선스가 지정되어 있지 않습니다. 공개 저장소로 전환하기 전에 프로젝트 사용·수정·배포 조건에 맞는 라이선스를 선택해 추가해야 합니다.
