# 변경 이력

이 문서는 HotspotSocks의 주요 변경 사항을 기록합니다. 버전 번호는 [Semantic Versioning](https://semver.org/lang/ko/)을 따릅니다.

## [1.0.0] - 2026-09-20

첫 공개 준비 기준 버전입니다.

### 추가

- 개인용 핫스팟 클라이언트를 위한 SOCKS5 `NO AUTH`, TCP `CONNECT`
- SOCKS5 `UDP ASSOCIATE` 및 UDP 릴레이
- 선택형 HTTP 전달 및 HTTPS `CONNECT` 프록시
- 수동 구성용 `wpad.dat`/PAC 제공
- 자동·시스템 기본·셀룰러 전용 송신 경로
- 사설망 및 특수 목적지 접근 정책
- 연결·트래픽·거부 통계와 최대 128개 기본 동시 연결
- 백그라운드 지속 처리 가능성 실험
- 한국어 중심의 설정·상태·진단 화면
- 실제 기기 검증을 위한 보안, 처리량, half-close, TCP/UDP 보조 도구

### 보안 및 공개 준비

- 개인 Apple Team ID와 번들 식별자를 Git에서 제외되는 `Config/Local.xcconfig`로 분리
- 공개 기본 번들 식별자를 `com.example.HotspotSocks`로 설정
- 인증서, 프로비저닝 프로파일, 환경 변수, Xcode 사용자 데이터 및 빌드 산출물 제외 규칙 추가

### 남은 검증

- Phase 12 PAC 클라이언트 적용과 HTTP/PAC 통합 실제 기기 검증
- 장시간 백그라운드, 저전력, 발열 및 일부 확장 성능 검증
