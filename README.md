# 위스퍼 필기 (whisper-notes)

강의 중 아이패드에서 PDF 강의자료에 필기하면서 녹음을 준실시간으로 전사하고, 강의가 끝나면 고정확도 재전사와 요약을 만드는 앱. 전사(WhisperKit)와 요약(Foundation Models)은 기기 안에서 한다.

- 계획과 설계: [PLAN.md](PLAN.md)
- 지금은 M0 단계다: 빈 앱을 CI에서 빌드해 TestFlight로 설치하는 데까지

## 받기와 설치

Mac 없이 GitHub Actions에서 빌드한다. 설치는 두 가지다.

- **TestFlight**: main에 푸시하면 CI가 기기용 빌드를 정식 서명해 App Store Connect에 올린다. 아이패드의 TestFlight 앱으로 설치한다 (내부 테스터는 심사 없이 받고, 한 빌드는 90일 동안 쓸 수 있다). 다른 브랜치는 Actions에서 수동 실행할 때 "TestFlight에 올리기"를 고르면 올린다 (testflight 환경이 그 브랜치를 허락해야 한다)
- **LiveContainer**: [Actions](../../actions)의 성공한 실행에서 아티팩트 `whispernotes-ipa-<실행 번호>`를 내려받아 설치한다. 서명 없는(가짜 서명) IPA다

설치한 앱이 어느 빌드인지는 버전(`0.1.<실행 번호>`, TestFlight와 LiveContainer 목록에 보인다)과 앱 화면의 "빌드" 항목(`#<실행 번호> <브랜치> <커밋>`)으로 알 수 있다.

### TestFlight 설정

`scripts/testflight.sh`가 가짜 서명 IPA를 받아, 프로필이 App Store용이고 이 앱의 App ID이며 그 인증서로 만든 것인지 확인한다. 그다음 이 실행만 쓰는 키체인으로 다시 서명해 `altool`로 올린다. 같은 빌드 번호가 이미 올라가 있으면(실패한 실행을 다시 돌릴 때) 다시 올리지 않는다. 다음 작업이 App Store Connect API(`scripts/asc.py`)로 처리 완료를 기다린다. 서명된 IPA는 아티팩트로 남기지 않는다.

1. 개발자 사이트에 App ID(번들 ID `io.github.videin.whispernotes`, `project.yml`의 `PRODUCT_BUNDLE_IDENTIFIER`)를 등록하고, Apple Distribution 인증서로 App Store용 프로필을 만든다
2. App Store Connect에 그 번들 ID로 앱을 만들고, 내부 테스트 그룹에 자기 계정을 넣는다
3. 저장소 Settings > Environments의 `testflight` 환경(배포 브랜치 main)에 비밀값을 넣는다. 하나도 없으면 올리지 않고 넘어간다

| 비밀값 | 내용 |
|---|---|
| `APPLE_DIST_P12_BASE64`, `APPLE_DIST_P12_PASSWORD` | Apple Distribution 인증서와 개인 키(.p12, base64)와 그 비밀번호. CSR은 맥 없이 `openssl`로 만들 수 있다 |
| `APPLE_PROFILE_BASE64` | App Store용 프로필(.mobileprovision, base64) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API 키 (.p8 파일 내용) |

엔타이틀먼트(백그라운드 GPU, 메모리 한도 등, PLAN.md §4)를 쓰게 되면 App ID에서 그 기능을 켜고 프로필을 다시 만든다.

## 요구 사항

- iPadOS 26.4 이상의 아이패드. 개발 대상은 iPad Pro M4 (PLAN.md §1)

## 라이선스

[MIT](LICENSE). TestFlight 스크립트(`scripts/testflight.sh`, `scripts/asc.py`)는 같은 저작자가 FaceLink 저장소에서 쓴 것을 가져왔다.
