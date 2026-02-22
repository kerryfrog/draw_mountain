## Building for Android

To build an Android App Bundle (AAB) for release, run the following command:

`flutter build appbundle`

This will create the AAB file in `build/app/outputs/bundle/release/app-release.aab`.

## 앱 버전 올리는 법

앱 버전을 올리려면 `pubspec.yaml` 파일의 `version` 필드를 수정해야 합니다.

예시:
```yaml
version: 1.0.0+1
```
여기서 `1.0.0`은 `build-name` (사용자에게 표시되는 버전), `1`은 `build-number` (내부 빌드 번호)입니다.

새로운 버전으로 빌드하려면 `flutter build` 명령어에 `--build-name`과 `--build-number`를 명시할 수 있습니다.

**Android (AAB 빌드 시):**
`flutter build appbundle --build-name=1.0.1 --build-number=2`

**iOS (IPA 빌드 시):**
`flutter build ipa --build-name=1.0.1 --build-number=2`

`--build-name`은 사용자에게 보여지는 앱 버전(예: `1.0.1`)을 의미하고, `--build-number`는 내부적으로 사용되는 빌드 번호(예: `2`)를 의미합니다. 새 버전을 출시할 때마다 이 값들을 적절히 증가시켜야 합니다.

