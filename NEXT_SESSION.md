# Next Session Prompt

Paste everything between the triple-backticks below into a fresh chat on
either machine. It's self-contained — the agent will have full context
without re-reading this project.

---

## Setup on the other machine (one-time)

```bash
# Swift toolchain (macOS 13+)
xcode-select --install

# GitHub CLI (for gh + auth cache)
brew install gh
gh auth login
```

## Resume the repo

```bash
mkdir -p ~/Documents/GitHub/Projects
cd ~/Documents/GitHub/Projects
gh repo clone frognation/saewoo-font-font-manager
cd saewoo-font-font-manager

# Current merged state lives on main.
git fetch origin
git checkout main
git pull --ff-only

# Build + run
swift run SaewooFont
```

If you want isolated feature work, create a short-lived branch off `main`
and merge it back when verified. Otherwise continuing directly on `main` is
acceptable for this project because the previous work branch has been merged.

---

## Copy-paste prompt for the next Claude session

```
Saewoo Font macOS 폰트매니저 작업 이어가자. 모든 컨텍스트는 두 문서에 있음:

  리포:       https://github.com/frognation/saewoo-font-font-manager
  로컬 경로:   ~/Documents/GitHub/Projects/saewoo-font-font-manager
  브랜치:     main  (이전 work/compB 브랜치는 main으로 병합됨)

시작 전에 반드시 다음 세 파일을 **이 순서대로** 읽어서 전체 맥락 파악해줘:

  1. HANDOFF.md          — 전체 변경사항 + "Queued for the next session"
                           섹션에 이번에 할 일 우선순위까지 정리돼 있음
  2. README.md           — 아키텍처, 폴더 구조, Fork 툴 사용법, 실행 방법
  3. Sources/SaewooFont/ — 실제 코드. 특히 Services/FontLibrary.swift (중앙 코디네이터),
                           Services/UFOExporter.swift (Fork 구현),
                           Services/SystemFontGuard.swift (중복 제거 안전장치)

## 현재 상태 한 줄 요약

네이티브 Swift + SwiftUI macOS 폰트매니저. macOS 13+, SPM 기반.
CTFontManager .session 스코프 활성화, 자동 카테고리+무드 분류, Projects/Palettes,
.rightfontlibrary import, 다른 매니저 활성 폰트 포착, Adobe Fonts 자동 인식,
Google Fonts browse/download, Fork (UFO/Designspace export), Proof Sheet glyph
detail popover까지 들어와 있음. 키보드 입력 문제는 해결됨.

**성능**: Session 4에서 대규모 성능 패스 완료 (아직 커밋 안 됨, 워킹트리 상태).
사이드바 렌더 6775ms → 0.1ms, 즐겨찾기 토글 170ms → 6.6ms, 정착 메모리
437MB → 364MB. 단 **런치 피크 메모리는 549MB → 712MB로 악화**됨 (캐시 디코드가
메인스레드를 막는 대신 백그라운드에서 UI 구성과 동시에 돌기 때문).
자세한 내용과 남은 이슈는 HANDOFF.md "Session 4" 참고.

성능 회귀 확인은 항상 **release 빌드**로:
```bash
swift build -c release && ./.build/arm64-apple-macosx/release/SaewooFont --bench
```
debug 빌드 수치는 의미 없음.

## HANDOFF.md "Queued for the next session"에 적힌 우선순위 (이걸 이어서 하면 됨)

  0. **(신규·최우선) library-cache.json을 바이너리/스트리밍 포맷으로 교체.**
     60MB JSON 디코드가 런치 피크 메모리 712MB와 1.2초 디코드의 원인.
     디코드 시간·피크 메모리·파일 크기를 한 번에 잡을 수 있는 유일한 항목.
  1. Duplicates 툴 — 삭제 전 백업 시스템 (복구 가능한 안전한 저장소)
  2. Duplicates 툴 — 리스트 뷰 필터 (경로 / 이름 / 용량 정렬)
  3. Duplicates 툴 — source별 delete-lock (절대 지우지 않을 소스 지정)

위 세 개 중에서 [번호]번을 구현해줘. 설계 → 구현 → 빌드 검증 → 커밋/푸시 순.
작업 전에는 HANDOFF.md Session 2 섹션을 꼭 확인해서 기존 패턴(SystemFontGuard,
derivedVersion 캐싱, Task.detached 캡처 방식, NewCollectionPrompt sheet 패턴)을
따라줘.

## 작업 규칙

- 현재 기준 브랜치는 main. 큰 실험은 feature 브랜치를 따도 되지만, 낡은 work/compB 지침은 무시.
- 커밋마다 `swift build` 또는 `/usr/bin/xcrun swift build` 통과 확인 후 푸시
- 커밋 메시지는 지금까지 스타일 그대로 (feat / fix / chore / 이유 본문 + Co-Authored-By)
- 다른 컴에서도 같은 리포 작업 중일 수 있음 → 시작할 때 `git pull --ff-only`, 끝날 때
  반드시 push. force push 금지.
- 내 폰트 라이브러리는 **77k+ faces**라서 성능 민감 — 새 기능도 캐싱/debounce 고려해야 함.
- 성능에 영향 있는 변경 뒤엔 `--bench` 돌려서 HANDOFF.md Session 4 표와 비교할 것.
- `FontLibrary`에 자주 바뀌는 `@Published` 추가 금지 (14개 뷰가 통째로 재렌더됨).
  선택/프리뷰/검색 상태는 `Services/UIState.swift`로.
```

---

## Cross-machine workflow (읽어두면 됨)

- **`main`**: 현재 활성 브랜치. 이전 `work/compB-20260422` 내용은 병합 완료.
- **feature branches**: 큰 실험이나 충돌 위험이 있는 작업에서만 `codex/...` 또는 `work/...`로 생성.
- 다른 컴으로 옮길 때:
  ```bash
  git status
  git push origin main                  # 커밋이 있다면 떠나기 전 push
  ```
- 다른 컴에서 이어갈 때:
  ```bash
  git fetch origin
  git checkout main
  git pull --ff-only
  ```
- feature 브랜치를 썼다면 최종 병합은 fast-forward 선호:
  ```bash
  git fetch origin
  git checkout main
  git merge --ff-only <feature-branch>
  git push origin main
  ```
