AIUsageMenuBar GitHub Release Flow

목표
- GitHub에 푸시하면 macOS 패키지를 자동 생성한다.
- 태그를 푸시하면 GitHub Releases에 ZIP과 SHA256 파일을 자동 업로드한다.

무엇이 만들어지나
- `AIUsageMenuBar.app`
- `AIUsageMenuBar-x.y.z.zip`
- `AIUsageMenuBar-x.y.z.sha256`
- Homebrew cask 메타데이터는 tap 저장소 `BestSonginTheWorld/homebrew-ai-usage-bar`에서 관리

자동화 구성
- `.github/workflows/package.yml`
  - `pull_request`, `push` to `main`, `workflow_dispatch`에서 실행
  - macOS runner에서 테스트 후 ZIP artifact 생성
  - 생성물은 GitHub Actions artifact로 다운로드 가능
- `.github/workflows/release.yml`
  - `v*` 태그 푸시에서 실행
  - macOS runner에서 테스트 후 ZIP 생성
  - GitHub Release에 asset 업로드

유지보수자 사용법
1. 코드를 `main`에 푸시한다.
2. GitHub Actions의 `Package` workflow에서 dev artifact를 확인한다.
3. 릴리스할 버전이면 태그를 만든다.

예시
```bash
git tag v0.1.0
git push origin v0.1.0
```

그러면 GitHub Releases에 아래 파일이 자동 등록된다.
- `AIUsageMenuBar-0.1.0.zip`
- `AIUsageMenuBar-0.1.0.sha256`

버전 규칙
- 태그 `v0.1.0` -> 앱/패키지 버전 `0.1.0`
- 개발용 artifact는 `dev-<short_sha>` 형식 사용

현재 한계
- App Store 배포가 아니다.
- Apple Developer ID 서명 및 notarization은 아직 포함하지 않았다.
- 따라서 외부 사용자 Mac에서는 첫 실행 시 Gatekeeper 경고가 나타날 수 있다.

Homebrew 설치 방식
```bash
brew install --cask BestSonginTheWorld/ai-usage-bar/bestsongintheworld-ai-usage-bar
```

주의
- tap 저장소는 `https://github.com/BestSonginTheWorld/homebrew-ai-usage-bar` 이다.
- `--cask`는 이 프로젝트가 CLI formula가 아니라 macOS 앱 번들이기 때문에 필요하다.
- Homebrew cask 설치는 즉시 `launchctl bootstrap` 하지 않는다. 설치 후 앱을 한 번 직접 열고, 자동 시작은 다음 로그인부터 적용된다.
- 현재 cask는 릴리스 ZIP의 URL과 SHA256을 직접 가리킨다.
- 새 버전을 릴리스할 때는 `Casks/bestsongintheworld-ai-usage-bar.rb`의 `version`과 `sha256`도 같이 갱신해야 한다.
