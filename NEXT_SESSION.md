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

# Pull the working branch — do NOT check out main directly.
git fetch origin
git checkout work/compB-20260422
git pull

# Build + run
swift run SaewooFont
```

If you're continuing on a third machine, create a new dated branch
(`work/compC-YYYYMMDD`) off the latest `work/compB-20260422` so you
don't collide with unpushed work from another machine.

---

## Copy-paste prompt for the next Claude session

```
Saewoo Font macOS 폰트매니저 작업 이어가자. 모든 컨텍스트는 두 문서에 있음:

  리포:       https://github.com/frognation/saewoo-font-font-manager
  로컬 경로:   ~/Documents/GitHub/Projects/saewoo-font-font-manager
  브랜치:     work/compB-20260422  (절대 main에 직접 커밋 금지, rebase 후 fast-forward only)

시작 전에 반드시 다음 세 파일을 **이 순서대로** 읽어서 전체 맥락 파악해줘:

  1. HANDOFF.md          — 2 세션에 걸친 모든 변경사항 + "Queued for the next session"
                           섹션에 이번에 할 일 우선순위까지 정리돼 있음
  2. README.md           — 아키텍처, 폴더 구조, Fork 툴 사용법, 실행 방법
  3. Sources/SaewooFont/ — 실제 코드. 특히 Services/FontLibrary.swift (중앙 코디네이터),
                           Services/UFOExporter.swift (Fork 구현),
                           Services/SystemFontGuard.swift (중복 제거 안전장치)

## 현재 상태 한 줄 요약

네이티브 Swift + SwiftUI macOS 폰트매니저. macOS 13+, SPM 기반.
CTFontManager .session 스코프 활성화, 자동 카테고리+무드 분류, Projects/Palettes,
.rightfontlibrary import, 다른 매니저 활성 폰트 포착, Adobe Fonts 자동 인식,
Fork (UFO/Designspace export) 완비. 키보드 입력/성능 모두 잡힘.

## HANDOFF.md "Queued for the next session"에 적힌 우선순위 (이걸 이어서 하면 됨)

  1. Duplicates 툴 — 삭제 전 백업 시스템 (복구 가능한 안전한 저장소)
  2. Duplicates 툴 — 리스트 뷰 필터 (경로 / 이름 / 용량 정렬)
  3. Duplicates 툴 — source별 delete-lock (절대 지우지 않을 소스 지정)
  4. Google Fonts 커넥터 — 카탈로그 fetch + 다운로드 + 설치/제거

위 네 개 중에서 [번호]번을 구현해줘. 설계 → 구현 → 빌드 검증 → 커밋/푸시 순.
작업 전에는 HANDOFF.md Session 2 섹션을 꼭 확인해서 기존 패턴(SystemFontGuard,
derivedVersion 캐싱, Task.detached 캡처 방식, NewCollectionPrompt sheet 패턴)을
따라줘.

## 작업 규칙

- 항상 work/compB-20260422 브랜치에서 작업 (이 컴이든 다른 컴이든)
- 커밋마다 `swift build` 통과 확인 후 푸시
- 커밋 메시지는 지금까지 스타일 그대로 (feat / fix / chore / 이유 본문 + Co-Authored-By)
- 다른 컴에서도 같은 리포 작업 중일 수 있음 → 시작할 때 `git pull --ff-only`, 끝날 때
  반드시 push. force push 금지.
- 내 폰트 라이브러리는 45k+ faces라서 성능 민감 — 새 기능도 캐싱/debounce 고려해야 함.
```

---

## Cross-machine workflow (읽어두면 됨)

- **`main`**: 안정 상태. 다른 컴에서 내가 직접 병합할 때만 업데이트됨.
- **`work/compB-*`**: 내가 이 컴에서 작업하는 브랜치. 현재 활성.
- 다른 컴으로 옮길 때:
  ```bash
  git push origin work/compB-20260422   # 떠나기 전 (필수)
  ```
- 다른 컴에서 이어갈 때:
  ```bash
  git fetch origin
  git checkout work/compB-20260422       # 같은 브랜치 사용
  git pull --ff-only
  ```
- `main` 따라잡기가 필요해지면:
  ```bash
  git fetch origin
  git rebase origin/main
  git push --force-with-lease
  ```
- 최종 병합은:
  ```bash
  git checkout main
  git merge --ff-only work/compB-20260422
  git push origin main
  ```
