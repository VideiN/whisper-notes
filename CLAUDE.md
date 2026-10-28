# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트

위스퍼 필기: 아이패드에서 PDF 강의자료에 필기하면서 강의를 녹음·전사(WhisperKit)하고 요약(Foundation Models)하는 앱. **설계와 단계(M0~M4)의 기준은 `PLAN.md`**다. 기능을 만들기 전에 읽는다.

## 빌드와 시험

사용자는 Windows만 쓰고 Mac이 없다. **빌드는 GitHub Actions(`.github/workflows/ios.yml`, `macos-26` 러너)에서만 된다.** 이 PC에서는 Swift를 컴파일할 수 없으므로, push한 뒤 CI 결과로 확인한다 (`gh run watch`, `gh run view --log-failed`). `.md`만 바꾼 push는 CI를 돌리지 않는다.

- 잡 `simulator`: 스크립트 시험(`python3 -m unittest discover -s scripts -v`) → 시뮬레이터용 빌드 → `scripts/ci-run-simulator.sh`가 iPad 시뮬레이터에서 앱을 띄워 로그의 `build: #<실행 번호> ` 줄을 확인한다. 로그·스크린숏은 아티팩트 `app-simulator-run`
- 잡 `ipa`: 기기용 빌드 → 가짜 서명 IPA, 아티팩트 `whispernotes-ipa-<실행 번호>`. 아이콘·개인정보 매니페스트·TestFlight에 필요한 Info.plist 키가 있는지도 본다
- 잡 `testflight`·`testflight-check`: main 푸시나 수동 실행("TestFlight에 올리기")에서만. `scripts/testflight.sh`가 배포 인증서로 다시 서명해 올리고, `scripts/asc.py wait-build`가 처리 완료를 기다린다. 비밀값은 GitHub `testflight` 환경에 있다 (배포 브랜치 main). 이 두 스크립트는 FaceLink 저장소(`VideiN/FaceLink`)에서 가져왔다
- `WhisperNotes.xcodeproj`는 저장소에 없다. `project.yml`(XcodeGen)에서 `scripts/build.sh`가 매번 만든다. 파일·설정을 더하면 `project.yml`을 고친다
- Python 스크립트 시험은 이 PC에서도 돌릴 수 있다: `python -m unittest discover -s scripts -v` (이 PC에서는 `python3`가 아니라 `python`)

## 구조

- `WhisperNotes/`: 앱 (SwiftUI). 기본 격리가 `MainActor`다 (`SWIFT_DEFAULT_ACTOR_ISOLATION`). 메인 밖에서 도는 타입은 `nonisolated`를 붙인다
- 로그는 `log()`: 표준 출력과 앱의 "기록" 화면(최근 1,000줄, 공유 가능). CI가 `build: ` 줄을 찾으므로 그 문구를 바꾸면 `scripts/ci-run-simulator.sh`도 고친다
- 빌드 정보: `scripts/build.sh`가 CI 실행 번호를 버전 `0.1.<번호>`와 빌드 설정 `WHISPERNOTES_BUILD_*`로 넘기고 → `WhisperNotes/Info.plist`의 `WhisperNotesBuild` → `BuildInfo.swift`

## 정해진 것

- 번들 ID `io.github.videin.whispernotes`, 앱 이름 "위스퍼 필기", 아이패드 전용, 최소 iPadOS 26.4 (PLAN.md §1)
- 사용자와는 한국어로 소통하고, 앱 화면 문구도 한국어다. 문서·주석은 쉬운 한국어로 쓴다
- 커밋: 한국어 제목 한 줄, 본문에 사용자 요청(인용)과 바뀐 점, 끝에 Co-Authored-By
