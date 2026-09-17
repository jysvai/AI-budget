# 아이폰 단독 카드 알림 수집

사용자 확정 조건: PC 상시 실행, 자체 서버, 별도 Bluetooth 중계 기기에 의존하지 않습니다. iOS 17 이상과 iPhone 16 Pro를 대상으로 합니다.

## 확인된 공식 경로와 적용 가능성

1. 일반 iOS 앱의 UserNotifications/Notification Service Extension은 자기 앱에 오는 알림만 처리합니다. 다른 카드사 앱의 알림 보관함을 읽는 범용 권한은 없습니다. iloader 설치가 OS 권한을 확대하지 않습니다.
2. Apple ANCS는 외부 Bluetooth 기기가 아이폰 알림을 읽는 기능입니다. 휴대폰 단독이라는 조건에 맞지 않아 PC 중계 실험 구현을 제거했습니다.
3. 최신 Accessory Notifications는 accessory companion app과 연결된 액세서리를 위한 경로입니다. Apple 문서상 고객 설치는 EU 위치와 EU Apple 계정 제약이 있고 개발 테스트는 다른 지역도 허용됩니다. 이것이 한국의 일반 사이드로드 앱에서 무조건 동작하거나 액세서리 없이 쓸 수 있다는 뜻은 아닙니다. iOS 버전, entitlement, 개발 프로비저닝 및 실제 accessory 요구사항 확인 전에는 채택할 수 없습니다.
4. Wallet의 Transaction 개인 자동화는 지원 카드 거래에 사용할 수 있고 잠금 상태 자동 실행을 허용합니다. 앱은 `Wallet 거래 기록` App Intent를 제공합니다.
5. SMS와 이메일 개인 자동화는 `카드 거래 알림 기록` App Intent에 본문을 넘깁니다. 사용자가 앱에서 켠 카드사와 직접 추가한 감지어만 승인합니다.
6. 푸시만 제공하는 카드는 거래 탭에서 화면 캡처를 선택하거나 복사한 문구를 붙여넣습니다. iPhone 16 Pro에서는 `스크린샷 찍기 → 푸시 화면 OCR 기록` 단축어를 액션 버튼에 지정해 한 번 누르는 흐름도 제공합니다. Vision OCR은 기기에서 실행되고 이미지·원문은 저장하거나 전송하지 않지만, 이 경로에는 사용자 액션이 한 번 필요합니다.
7. 탈옥이나 운영체제 취약점 의존 방식은 본 구현에 추가하지 않았습니다.

## 실기기 확인 항목

- 각 카드가 Wallet Transaction 자동화를 노출하는지.
- 카드사가 제공하는 SMS/이메일과 실제 승인·취소·환불 형식.
- 잠금 상태에서 각 개인 자동화가 즉시 실행되는지와 OCR 인식률.

## 공식 근거

- https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension
- https://support.apple.com/guide/shortcuts/apd65c67538a/ios
- https://support.apple.com/guide/shortcuts/add-automations-apdfbdbd7123/ios
- https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- https://developer.apple.com/documentation/accessorynotifications
- https://developer.apple.com/documentation/AccessoryTransportExtension/receiving-ios-notifications-on-an-accessory
- https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html

Xcode 컴파일과 실제 아이폰 자동화 성공 여부는 아직 검증하지 않았습니다.
