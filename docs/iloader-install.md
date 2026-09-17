# iloader / SideStore 설치

`C:\Users\yunseok\Desktop\working-holiday-english`의 `docs/SideStore-설치가이드.md`, `ios/README.md`, `.github/workflows/build-ipa.yml`을 참고해 이식했습니다. 영어 앱의 저장소나 앱 설정은 수정하지 않았습니다.

## 채택한 방식

Windows의 소스 → GitHub Actions macOS 빌드 → AIBudget.ipa → iloader 직접 설치 또는 기존 SideStore에서 가져오기 → 앱 안에서 설정.

영어 앱처럼 매주 PC 연결을 줄이려면 iloader로 설치한 SideStore를 계속 사용합니다. 이미 같은 아이폰에 SideStore가 설치되어 있다면 다시 설치할 필요 없이 가계부 IPA를 가져오면 됩니다.

## 개발·배포 담당자

1. 가계부 전용 GitHub 저장소에 이 프로젝트를 올립니다. 영어 앱 저장소를 덮어쓰지 않습니다.
2. Actions → **iOS IPA for iloader** → Run workflow. 버전은 `0.2.0` 등으로 지정합니다.
3. 기본값은 artifact만 생성합니다. 공개 릴리스가 필요할 때만 `publish`를 선택합니다.
4. artifact `ai-budget-ipa`에서 `AIBudget.ipa`를 받습니다.
5. 릴리스 배포를 선택했다면 `apps.json`도 릴리스 자산으로 생성됩니다. SideStore의 Sources에 `https://github.com/<소유자>/<가계부저장소>/releases/latest/download/apps.json`을 등록하면 이후 릴리스를 따라갑니다. 아직 저장소를 만들거나 릴리스를 게시하지 않았으므로 실제 URL은 없습니다.

영어 앱과 달리 위젯 extension과 App Group 권한이 필요합니다. 빌드에서 entitlement를 지우지 않고 임시 서명에 담아 설치 도구에 전달합니다. 이 임시 서명은 Apple 계정 서명을 대체하지 않습니다.

**실기기 필수 점검:** iloader/SideStore 재서명 후 앱과 위젯이 같은 App Group을 사용해야 합니다. 설치 도구가 식별자를 재작성할 수 있으므로 원래 group 문자열과 실행 시 접근 가능한 group이 일치하는지 확인해야 합니다. 호환성이 검증되기 전 위젯이 작동한다고 보장하지 않습니다. extension 제거를 선택하면 위젯도 제거됩니다.

## 사용자가 하는 설치

1. 기존 iloader/SideStore 환경을 사용합니다. 새로 설치할 경우 [공식 iloader](https://github.com/nab138/iloader)에서 배포본을 받습니다.
2. iloader 직접 설치: USB로 연결 → 아이폰에서 컴퓨터 신뢰 → iloader에서 기기 선택 → IPA 설치 기능으로 `AIBudget.ipa` 선택 → 도구 안내에 따라 본인 Apple 계정으로 서명합니다.
3. SideStore 사용 시: Wi-Fi 및 현재 SideStore 공식 안내에서 요구하는 VPN/페어링 상태 확인 → My Apps의 가져오기 기능으로 IPA 선택. 이미 Source가 게시되어 있다면 Sources에서 설치합니다.
4. 필요한 경우 iOS 설정에서 개발자 앱 신뢰 및 개발자 모드를 사용자가 켭니다. Apple 로그인/2단계 인증은 설치 도구에서 직접 진행합니다.
5. 위젯을 사용할 것이므로 App Extensions를 유지합니다.

무료 Apple 계정의 서명 만료는 설치 도구로 없어지지 않습니다. SideStore의 갱신 상태를 확인합니다. 기존 영어 앱과 가계부, SideStore를 함께 쓰면 계정의 설치/식별자 한도도 확인해야 합니다. 설치 문제를 해결하려고 기존 앱부터 삭제하지 마세요. 삭제하면 로컬 장부도 사라질 수 있습니다.

## 앱 첫 설정

앱 → 설정 → 예상 월급·저축·고정비 → 사용할 카드사 선택/추가 → 월급 확인일·알림 시간 → AI 분석 방식 및 전송 동의 → 알림 허용 → 카드 거래 자동화 안내 → 결산 자동화 안내 → 위젯 추가.

- 카드번호, CVC, 유효기간, 카드사 비밀번호를 입력하는 기능은 없습니다.
- 가능한 카드는 Wallet 거래 자동화를 우선 사용하고, 카드사 SMS/이메일은 본문 자동화로 승인·취소·환불을 기록합니다.
- 타 앱 푸시를 직접 감시하지는 못합니다. 푸시만 오는 카드는 거래 탭에서 캡처를 선택하면 아이폰 내부 OCR로 처리하며 이미지와 원문을 저장하지 않습니다.
- 개인 AI를 쓸 때의 API 키는 카드 정보와 별개이며 해당 AI 서비스에서 발급합니다.
- 문자에 포함된 카드번호 등은 기록 전에 마스킹합니다. 미지원 문자는 마스킹된 상태로 검토함에 보관합니다.

공식 참고: https://github.com/nab138/iloader / https://docs.sidestore.io
