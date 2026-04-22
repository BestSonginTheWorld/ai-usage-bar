AIUsageMenuBar GitHub Release Flow

목표
- GitHub에 푸시하면 macOS 패키지 artifact를 자동 생성한다.
- 태그를 푸시하면 GitHub Releases에 `.pkg`와 `SHA256` 파일을 자동 업로드한다.

무엇이 만들어지나
- `AIUsageMenuBar.app`
- `AIUsageMenuBar-x.y.z.pkg`
- `AIUsageMenuBar-x.y.z.sha256`

자동화 구성
- `.github/workflows/package.yml`
  - `pull_request`, `push` to `main`, `workflow_dispatch`에서 실행
  - macOS runner에서 테스트 후 `.pkg` artifact 생성
  - 생성물은 GitHub Actions artifact로 다운로드 가능
- `.github/workflows/release.yml`
  - `v*` 태그 푸시에서 실행
  - macOS runner에서 테스트 후 `.pkg` 생성
  - GitHub Release에 asset 업로드

유지보수자 사용법
1. 코드를 `main`에 푸시한다.
2. GitHub Actions의 `Package` workflow에서 dev artifact를 확인한다.
3. 릴리스할 버전이면 태그를 만든다.

예시
```bash
git tag v0.1.1
git push origin v0.1.1
```

그러면 GitHub Releases에 아래 파일이 자동 등록된다.
- `AIUsageMenuBar-0.1.1.pkg`
- `AIUsageMenuBar-0.1.1.sha256`

버전 규칙
- 태그 `v0.1.1` -> 앱/패키지 버전 `0.1.1`
- 개발용 artifact는 `dev-<short_sha>` 형식 사용

현재 한계
- App Store 배포가 아니다.
- Apple Developer ID 서명 및 notarization은 아직 포함하지 않았다.
- 따라서 외부 사용자 Mac에서는 첫 실행 시 Gatekeeper 경고가 나타날 수 있다.

설치 UX
- 사용자는 `.pkg`를 더블클릭해 설치한다.
- 설치 후 `/Applications/AIUsageMenuBar.app`를 한 번 직접 실행해야 한다.
- 앱 첫 실행 시 설정 파일, collector runtime, 자동 시작용 LaunchAgent 파일을 사용자 홈 디렉터리에 생성한다.
