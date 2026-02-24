# Android 배포 가이드

Play Console 업로드용 파일은 `release` 서명된 AAB/APK여야 합니다.
디버그 서명 파일은 업로드할 수 없습니다.

## 1) 버전 올리기

`pubspec.yaml`의 `version`을 올립니다.

```yaml
version: 1.0.0+1
```

- `1.0.0`: 사용자에게 보이는 버전(`build-name`)
- `1`: 내부 빌드 번호(`build-number`)

필요하면 빌드 시 직접 지정:

```bash
flutter build appbundle --release --build-name=1.0.1 --build-number=2
```

## 2) 업로드 키(keystore) 준비

최초 1회만 생성:

```bash
keytool -genkeypair -v \
  -keystore android/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

## 3) `key.properties` 설정

예시 파일 복사:

```bash
cp android/key.properties.example android/key.properties
```

`android/key.properties`에 실제 값 입력:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=../upload-keystore.jks
```

주의:

- `android/key.properties`, `upload-keystore.jks`는 절대 공개 저장소에 올리지 마세요.
- 현재 프로젝트 `.gitignore`에 이미 제외되어 있습니다.

## 4) 릴리즈 빌드

### AAB (Play Console 권장)

```bash
flutter build appbundle --release
```

출력 파일:

- `build/app/outputs/bundle/release/app-release.aab`

### APK (테스트/직접 배포)

```bash
flutter build apk --release
```

출력 파일:

- `build/app/outputs/flutter-apk/app-release.apk`

## 5) 자주 나오는 오류

### "디버그 모드로 서명한 APK 또는 Android App Bundle..."

원인:

- `release`가 디버그 키로 서명됨
- 또는 `android/key.properties`가 없거나 값이 잘못됨

해결:

1. `android/key.properties` 파일 존재 확인
2. `storeFile`, 비밀번호, `keyAlias` 값 확인
3. 다시 빌드:

```bash
flutter clean
flutter pub get
flutter build appbundle --release
```



Prompt: A minimalist flat design app icon on a orange background. The icon features a simple white line art of a mountain. A dashed line traces a path from the bottom to the peak, ending at a red checkered flag. Modern, clean, professional vector style, high contrast. no border. 

컨투어 트랙 (Contour Track)
고도의 순간
등선 