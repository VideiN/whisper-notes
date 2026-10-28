# PLAN.md — PDF 필기 + 강의 전사 iPad 앱

## 1. 개요

강의 중 PDF 강의자료에 필기하면서, 녹음된 강의를 준실시간으로 전사해 가끔 확인하며 내용을 따라잡고, 강의 종료 후 고정확도 재전사와 요약을 제공하는 iPad 전용 앱.

- 대상 기기: iPad Pro M4 1TB (RAM 16GB)
- 대상 OS: iPadOS 26.4 이상 (개인 기기용이므로 실제 iPad의 OS 버전에 맞춰 올리고 버전 분기를 두지 않음)
- 처리 방식: 전사·요약 모두 온디바이스 (요약 PCC 옵션은 서드파티 접근 가능 여부 미확인)
- 개발 계정: Apple Developer Program 유료 계정 보유

---

## 2. MVP 범위 (4개 기능)

| # | 기능 | 핵심 구성 |
|---|---|---|
| 1 | 필기 | PDFKit + PencilKit 페이지별 오버레이 |
| 2 | 준실시간 전사 | VAD 청크(최대 30초) → WhisperKit + Whisper large-v3 Turbo |
| 3 | 완료 후 전사 | 저장된 녹음 전체 → WhisperKit + Turbo 또는 large-v3 (M2 CER 결과로 결정) |
| 4 | 전사 내용 요약 | Foundation Models, 재귀 요약(구간 요약 → 토큰 예산 안에 들 때까지 반복 통합) |

### MVP에서 제외 (백로그로 이동)
- 필기 ↔ 오디오 ↔ 전사 타임라인 연동 (필기 탭 → 해당 시점 재생 등)
- 페이지 전환 타임라인 활용 (기록은 MVP에서 함, 아래 참고)
- PDF 키워드 추출 → Whisper 프롬프트 주입
- Apple SpeechAnalyzer 즉시층 (한국어 품질 우려로 제외. 단 M2 CER 비교군에는 선택적으로 포함)

### 제외하지만 데이터는 저장할 것
- 녹음 세그먼트별 벽시계 시작·끝 시각 (중단·재개가 있어도 오디오 시간축 ↔ 실제 시각 변환 가능)
- Whisper 세그먼트별 시작·끝 타임스탬프 (세션 오디오 시간축 기준)
- 페이지 전환 이벤트 `(시각, 페이지)` — 나중에 복원할 수 없는 데이터
- 필기 시각: `PKStrokePath.creationDate`로 PKDrawing에 이미 포함됨 → 별도 작업 없음
- 이유: 추가 비용이 거의 없고, 이후 연동 기능 추가 시 기존 노트 재처리를 피할 수 있음. UI에서는 사용하지 않음.

---

## 3. 기능별 설계

### 3.1 필기
- PDFKit `PDFView` + `PDFPageOverlayViewProvider`(iPadOS 16+)로 페이지마다 `PKCanvasView` 오버레이.
- 필기 데이터(`PKDrawing`)는 PDF에 flatten하지 않고 페이지별 별도 파일로 저장.
- Pencil 입력 지연이 최우선. 전사 연산이 메인 스레드·렌더링을 방해하지 않도록 분리.
- 대용량 PDF(수백 페이지)에서 메모리·스크롤 성능 확인.
- 구현 체크리스트:
  - `pdfView.isInMarkupMode = true` (없으면 PDFView가 터치를 가로챔)
  - `PKCanvasView.drawingPolicy = .pencilOnly` (손가락은 스크롤·확대)
  - 오버레이는 보이는 페이지에만 생성됨 → `pdfView(_:willEndDisplayingOverlayView:for:)`에서 저장 + 편집 중 디바운스 자동저장
  - 페이지 회전·cropBox·확대 상태에서 좌표 확인

### 3.2 준실시간 전사
- 녹음: `AVAudioEngine`으로 입력 수신.
  - 원본은 1~5분 단위 세그먼트 파일(`seg_NNNN.m4a`)로 저장하고 닫음. 단일 m4a는 닫기(moov atom 기록) 전에 크래시하면 전체를 읽을 수 없기 때문. 크래시 시 손실은 마지막 세그먼트 하나로 한정. 병합하지 않음.
  - 세그먼트마다 벽시계 시작·끝 시각을 `manifest.json`에 기록.
  - 동시에 16kHz mono로 변환(`AVAudioConverter`)해 전사 큐에 투입.
- 청크 분할: 고정 30초는 단어 중간을 자르므로, 무음 지점에서 자르고 최대 30초로 제한 (WhisperKit `chunkingStrategy: .vad` 또는 자체 VAD). 청크 내 세그먼트 타임스탬프에는 청크 시작 오프셋을 더해 저장.
- 모델: Whisper large-v3 Turbo (WhisperKit, CoreML).
- Compute 설정: **GPU 우선으로 시작**하고, 발열이나 사용 지장(Pencil 지연·프레임 드롭)이 있으면 Neural Engine으로 전환.
  - GPU 모드: mel·encoder·decoder `.cpuAndGPU`. ANE 모드: mel `.cpuOnly`, encoder·decoder `.cpuAndNeuralEngine`.
  - Compute 모드는 디버그 메뉴의 런타임 설정으로 둠. CoreML은 로드 시점에 compute units가 정해지므로 전환하면 모델을 다시 로드함. Mac 없이 TestFlight를 거치면 빌드 한 번이 느리므로, 재빌드 없이 앱 안에서 바꿔 가며 비교.
  - GPU 모드는 Pencil 렌더링과 GPU를 나눠 쓰게 되므로 이 부분이 판정의 핵심 (§9).
  - 백그라운드 제약: 녹음 중 화면 잠금·앱 전환 시 audio 백그라운드 모드로 앱은 계속 돌지만 GPU 작업은 허용되지 않음. 백그라운드 GPU 권한은 `BGContinuedProcessingTask` 안에서만 적용되므로 준실시간 전사에는 쓰지 않음 (완료 후 전사 전용, §3.3). GPU 모드에서는 백그라운드 진입 시 준실시간 전사를 멈추고 청크만 쌓아 두었다가 포그라운드 복귀 시 이어서 처리 (완료 후 전사가 전체를 다시 덮으므로 밀린 청크는 건너뛰어도 됨).
- 설정: 언어 `ko` 고정(자동 감지 끄기), 무음 청크 건너뛰기(VAD).
- 환각 대응: 한국어는 무음·소음 구간에서 "시청해주셔서 감사합니다"류 환각이 잘 알려져 있고, 에너지 VAD는 강의실 소음(프로젝터·공조)에 약함 → `noSpeechThreshold` / `logProbThreshold` / `compressionRatioThreshold` 설정 + 알려진 환각 문구 블랙리스트 후처리.
- 지연: 청크 길이 + 처리 시간 ≈ 30~60초. "가끔 확인하며 따라잡기" 용도로 허용 범위.
- UI: 접이식 전사 패널 1개.
- 자원 우선순위: 녹음 > 필기 렌더링 > 전사. 전사는 낮은 QoS로 실행, `thermalState` 상승 시 처리 간격 확대.
- 오디오 세션:
  - 중단(전화, Siri, 블루투스 마이크 해제) 처리.
  - `AVAudioEngineConfigurationChange` 알림(입력 경로 변경 시 엔진이 정지됨) 수신 시 엔진 재시작 + 새 세그먼트 시작.
  - 원거리 수음 품질을 위해 세션 모드 `.default`와 `.measurement` 비교.
- 참고 수치: Turbo는 iPad Pro M2에서 10분 오디오를 약 71초에 처리 (실시간 대비 약 12% 부하, 제작사 측정). M4는 실측 필요.

### 3.3 완료 후 전사
- 녹음 종료 후 세션의 세그먼트 전체를 순서대로 재전사 → 준실시간 결과를 통째로 교체.
- 모델: M2의 CER 비교로 결정 (§9).
  - 품질 향상의 상당 부분은 모델 차이보다 30초 고정 청크 경계 제거와 이전 문맥 사용에서 나올 가능성이 있음 (Turbo는 large-v3와 인코더가 같고 디코더만 4층).
  - Turbo 전체 파일 전사와 large-v3의 차이가 작으면 Turbo 단일 모델로 가고, large-v3 다운로드(약 3GB)·memory entitlement를 뺌.
- 참고 수치 (iPad Pro M2, 제작사 측정): large-v3는 10분 오디오에 약 380초 (90분 강의 ≈ 57분), Turbo는 약 71초 (90분 ≈ 11분).
- 청크 단위로 진행 상태를 저장해 중단 후 재개 가능하게 설계 (가장 중요).
- 실행 경로:
  - 기본: 충전 중 포그라운드 유지 모드 (`isIdleTimerDisabled = true`, 진행률 화면 표시).
  - 보조: `BGContinuedProcessingTask`(iPadOS 26+).
    - 사용자 동작(예: "전사 시작" 버튼)으로 제출해야 함.
    - 진행률은 시스템 UI가 표시 → Live Activity 별도 구현 불필요. `task.progress`를 꾸준히 갱신해야 하고, 보고가 멈추면 시스템이 종료할 수 있음. 사용자가 언제든 취소할 수 있으므로 재개 로직 필수.
    - Info.plist `BGTaskSchedulerPermittedIdentifiers`에 식별자 등록.
    - 백그라운드 GPU는 앱 전체에서 이 경로에서만 사용. 요청에 `requiredResources = .gpu`를 지정하고 background GPU entitlement를 추가. 대상 iPad의 지원 여부는 다른 앱에서 이미 동작을 확인함. 런타임 `supportedResources` 확인은 방어용으로만 두고, 없으면 ANE 모드로 다시 로드해서 진행.
    - 작업이 만료·취소되면 GPU 작업을 즉시 멈추고 진행 상태를 저장 (재개 로직과 공유).
    - 알려진 이슈: 백그라운드에서 CPU/ANE 작업이 4~5배 느려진다는 보고 → WhisperKit에서 실측 필요. whisper.cpp+Metal은 GPU 권한 없이 백그라운드 전환 시 크래시 보고 → 준실시간 전사가 백그라운드에서 GPU 작업을 내지 않도록 주의 (§3.2).
- 모델 배포: 앱 번들에 포함하지 않고 첫 사용 시 다운로드. 첫 로딩(기기 최적화) 시간이 길 수 있으므로 진행 표시. 저장 위치는 §7.

### 3.4 요약
- Foundation Models(온디바이스 약 3B) 사용.
- 제약: 컨텍스트 4096토큰, 입력+출력 공유. 한국어는 대략 1글자 ≈ 1토큰 (실제 값은 `tokenCount(for:)`로 측정).
- 분량 추정: 한국어 강의는 분당 약 250~350음절 → 90분 ≈ 2.2만~3.2만 자. 구간 입력을 ~2.5k토큰으로 잡으면 9~13구간이고, 구간 요약을 200토큰씩만 잡아도 통합 단계 입력이 1.8k~2.6k → 지시문·출력까지 더하면 한 번에 안 들어갈 수 있음.
- 방식: 재귀 요약. 전사본을 구간별로 요약 → 요약들의 합이 토큰 예산을 넘으면 다시 묶어 요약 → 예산 안에 들어오면 통합 요약.
- 입력: 완료 후 전사 결과 우선, 미완료 시 준실시간 결과로 임시 요약 가능.
- 가드레일: 강의 내용(의학·역사 등) 때문에 가드레일 오류가 날 수 있음 → 요약 용도의 `permissiveContentTransformations` 가드레일 사용 + 오류 처리.
- 실행: 포그라운드에서 실행 (백그라운드에서는 rate limit이 걸림).
- 옵션 (미확인): Private Cloud Compute 모델(32K 컨텍스트)로 분할 횟수 감소. 단 기기 밖 처리. iOS 26 기준 서드파티 앱은 온디바이스 모델만 쓸 수 있었으므로, 현재 OS에서 접근 가능한지 확인 전까지 계획에 넣지 않음.
- `SystemLanguageModel.default.availability` 확인, `contextSize` / `tokenCount(for:)`로 예산 관리 (iPadOS 26.4+ → §1 배포 타깃).

---

## 4. 기술 스택

| 영역 | 선택 |
|---|---|
| 언어/UI | Swift, SwiftUI (+ 필요 시 UIKit 래핑) |
| PDF/필기 | PDFKit, PencilKit |
| 오디오 | AVFoundation (`AVAudioEngine`, `AVAudioSession`, `AVAudioConverter`) — FFmpeg 미사용 |
| 전사 | WhisperKit (MIT) + Whisper large-v3 Turbo (large-v3는 M2 결과에 따라) |
| 요약 | Foundation Models framework |
| 백그라운드 | BackgroundTasks (`BGContinuedProcessingTask`) — 보조 경로 |
| 프로젝트 생성 | XcodeGen (YAML로 프로젝트·entitlements 관리) |

### 필요 Entitlements / Capabilities / Info.plist
- Background Modes: Audio (녹음 지속)
- `BGTaskSchedulerPermittedIdentifiers` (Info.plist, `BGContinuedProcessingTask` 식별자)
- 마이크 권한 (`NSMicrophoneUsageDescription`)
- `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (Files 앱에서 노트·로그·녹음 반출)
- `ITSAppUsesNonExemptEncryption = NO` (TestFlight 빌드마다 수출 규정 질문이 뜨는 것 방지)
- Increased Memory Limit (`com.apple.developer.kernel.increased-memory-limit`) — large-v3 채택 시에만
- Background GPU access for continued processing (`com.apple.developer.background-tasks.continued-processing.gpu`) — 완료 후 전사(`BGContinuedProcessingTask`) 전용. 대상 iPad 지원은 다른 앱에서 확인됨. 준실시간 전사에는 적용되지 않음.

---

## 5. 라이선스

개인 사용·사이드로딩 기준 문제 없음. 배포 시 앱 내 오픈소스 고지 화면에 아래 포함.

| 구성요소 | 라이선스 | 배포 시 의무 |
|---|---|---|
| Whisper large-v3 | Apache-2.0 | 고지문·NOTICE 유지 |
| Whisper large-v3 Turbo | MIT | 저작권 고지 |
| WhisperKit | MIT | 저작권 고지 |
| swift-transformers (WhisperKit 의존성) | Apache-2.0 | 고지문·NOTICE 유지 |

- 고지 목록은 `Package.resolved` 기준으로 전이 의존성까지 포함해 생성.
- GPL 컴포넌트(빌드 옵션에 따른 FFmpeg 등) 배제 → 오디오 디코딩은 AVFoundation.
- 퍼블릭 레포이므로 레포 자체 라이선스를 명시 (미명시 시 "모든 권리 보유").
- 녹음 대상: 본인이 참여한 강의 녹음은 합법. 단 학교 학칙·교수 허락 여부를 확인. 강의 내용은 저작물이므로 녹음·전사본 공유·공개 금지 (개인 학습용만). CER 테스트용 녹음·기준 전사도 레포에 커밋하지 않음.

---

## 6. 개발 환경 / CI·CD

### GitHub Actions (퍼블릭 레포, 표준 러너 무료)
- 러너: `macos-26` (GitHub 호스팅, 2026-02 GA, Xcode 26).
- 프로젝트: XcodeGen YAML → `xcodegen generate` → `xcodebuild`.
- 서명: App Store Connect API 키 + `xcodebuild -allowProvisioningUpdates` 자동 서명. Mac 없이 인증서를 만들려면 클라우드 관리 인증서를 사용 → API 키에 필요한 권한(Admin 여부) 확인.
- 빌드 번호: `CURRENT_PROJECT_VERSION`을 `github.run_number`로 자동 증가 (TestFlight는 같은 빌드 번호를 거부).
- 배포: TestFlight 업로드 → iPad에 설치.

### 퍼블릭 레포 보안 규칙
- 서명 인증서·API 키는 레포 시크릿에만 저장.
- `pull_request_target` 사용 금지 (포크 PR에 시크릿·쓰기 권한 노출).
- 서명·업로드 잡은 `main` 푸시 또는 태그에서만 실행.
- GitHub Environment에 본인 승인 필수 설정.
- Whisper 모델 가중치는 레포에 커밋하지 않음 (LFS 대역폭 한도).

### (보류) Xcode Cloud
- 퍼블릭 레포의 GitHub Actions 표준 러너가 무료라 옮길 이점이 분명하지 않고, 초기 워크플로 구성에 Mac이 필요함. 구체적인 필요가 생길 때만 검토.

### Mac 없는 기간의 디버깅 대체 수단
- 디버거·Instruments·실시간 콘솔 사용 불가.
- 로그: iOS의 `OSLogStore`는 현재 프로세스 로그만 읽을 수 있어서 크래시 직전 로그를 볼 수 없음 → 회전 파일 로거를 병행하고 앱 내에서 내보내기.
- MetricKit, TestFlight 크래시 리포트.
- Files 앱 노출(§4)로 로그·녹음 반출 (CER 테스트용 녹음 꺼내기에도 사용).
- 앱 내 디버그 오버레이: 메모리 사용량, `thermalState`, 전사 큐 상태, 처리 속도, 프레임 드롭 카운터 (Instruments 대체, Pencil 지연 지표), 현재 compute 모드(GPU/ANE). 디버그 메뉴에서 compute 모드 전환.

---

## 7. 데이터 저장 구조

노트 1개 = 패키지 디렉터리. PDF와 필기는 노트 단위, 녹음·전사·요약은 강의 회차(세션) 단위. 슬라이드 PDF 하나를 여러 회차에 쓸 수 있음.

```
Note_<id>/
├── document.pdf                # 원본 PDF
├── ink/
│   └── page_<n>.drawing        # 페이지별 PKDrawing (스트로크 생성 시각 포함)
├── sessions/
│   └── <session_id>/           # 강의 회차 1개
│       ├── audio/
│       │   ├── seg_0001.m4a    # 1~5분 단위 세그먼트, 병합하지 않음
│       │   └── manifest.json   # 세그먼트 순서 + 벽시계 시작·끝 시각
│       ├── transcript/
│       │   ├── live.json       # 준실시간 전사 (세그먼트 + 타임스탬프)
│       │   ├── final.json      # 완료 후 전사 (세그먼트 + 타임스탬프)
│       │   └── progress.json   # 완료 후 전사 재개용 진행 상태
│       ├── events.jsonl        # 페이지 전환 (시각, 페이지) append
│       ├── summary.md          # 요약 결과
│       └── meta.json           # 모델 버전, 생성일 등
└── meta.json                   # 노트 제목, 생성일 등
```

- 시간축: Whisper 타임스탬프는 세션 오디오 시간축(세그먼트를 이어붙인 기준). `manifest.json`으로 벽시계 시각과 변환. 필기(`creationDate`)·페이지 전환은 벽시계 시각이므로 manifest를 거쳐 오디오 위치와 연결됨.
- iCloud 동기화는 MVP 범위 밖.
- 모델 파일은 노트와 분리해 `Application Support`에 두고 `isExcludedFromBackup` 설정. `Caches`는 시스템이 지울 수 있어 수 GB를 다시 받게 될 수 있음.

---

## 8. 구현 순서 (마일스톤)

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| M0 | XcodeGen + GitHub Actions → TestFlight | 빈 앱이 iPad에 설치됨 |
| M1 | 필기 | PDF 열기, 페이지별 필기·저장·재열기 |
| M2 | 녹음 + 완료 후 전사 | 세그먼트 녹음을 전사, 중단 후 재개 동작. CER 비교로 완료 후 전사 모델 결정. 필기 중 파일 전사를 포그라운드에서 동시 실행 — GPU 모드로 먼저 측정하고, 발열·Pencil 지연이 있으면 ANE 모드로 재측정해 compute 모드 확정 |
| M3 | 준실시간 전사 | 필기 중 VAD 청크(최대 30초) Turbo 전사 패널 표시 |
| M4 | 요약 | 90분 강의 전사본 재귀 요약 생성 (4096토큰 예산 초과 없음) |

- M2를 M3보다 먼저 하는 이유: 파일 단위 전사가 가장 단순한 경로라 모델 다운로드·로딩·메모리·한국어 품질을 실시간 복잡도 없이 먼저 검증. 필기 + 전사 동시 실행은 앱 컨셉의 핵심 리스크라 M3 전에 파일 전사로 미리 확인.

---

## 9. 리스크 및 실측 항목

| 항목 | 확인 방법 |
|---|---|
| 한국어 전사 품질 | 본인 강의 녹음 약 10분 + 직접 만든 기준 전사로 CER 비교. 비교군: Turbo 30초 청크 / Turbo 전체 파일 / large-v3 전체 파일 (선택: 양자화 Turbo 626MB, SpeechAnalyzer). 한국어 띄어쓰기 차이를 없애기 위해 공백 제거 후 계산 |
| 필기 + 전사 동시 실행 시 발열·Pencil 지연 | M2에서 파일 전사로 먼저 확인, M3에서 90분 연속 세션 실측 |
| Compute 모드 (GPU 우선 → 필요 시 ANE) | 같은 녹음·같은 필기 작업으로 두 모드 비교: 처리 속도, `thermalState` 변화, 프레임 드롭, Pencil 지연 체감, 배터리. GPU에서 발열이나 사용 지장이 있으면 ANE로 확정 |
| 배터리 소모 | 90분 세션(녹음 + 준실시간 전사 + 필기) 전후 잔량 비교 |
| large-v3 메모리 사용량 (채택 시) | 디버그 오버레이 / MetricKit |
| 백그라운드 전사 속도 저하·중단 | `BGContinuedProcessingTask` 실측, 재개 로직 검증 |
| 모델 첫 로딩 시간 | 첫 실행 시간 측정, 진행 UI 확인 |
| 무음 구간 환각 | VAD·임계값·블랙리스트 적용 전후 비교 |
| 요약 품질 (한국어, 재귀 요약) | 구간 길이별 결과 비교 |

### 구현 시 문서·코드로 확인할 것
- WhisperKit `ModelComputeOptions`로 GPU/ANE 모드를 지정하는 방법, 모드 전환 시 모델 재로드·첫 로딩(기기 최적화) 시간
- Foundation Models PCC 모델의 서드파티 접근 가능 여부
- `contextSize` / `tokenCount(for:)` 도입 버전 (현재 26.4로 기재)
- 클라우드 관리 인증서 사용 시 App Store Connect API 키에 필요한 권한

---

## 10. 백로그 (MVP 이후)

- 필기 ↔ 오디오 ↔ 전사 타임라인 연동 (저장된 타임스탬프·manifest 활용)
- 페이지 전환 기록 활용, 전사 문장 ↔ PDF 페이지 정렬
- PDF 키워드 → Whisper 프롬프트 (224토큰 한도, 삽입 오류 지표로 효과 검증)
- 전사 문장 탭 → 해당 구간 오디오 재생
- "마지막 확인 이후" 따라잡기 UI
- 화자 분리, 검색, iCloud 동기화
