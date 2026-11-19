# MacSnow 작업 규칙

## PR마다 성능 체크 필수

모든 PR 본문에 **성능 체크 결과**를 붙여요. 결과가 없는 PR은 올리지 않아요.

1. `tools/perf.sh`로 이 브랜치와 `main`을 같은 조건에서 번갈아 재요. 비교 표(눈 내리는 중 / 미션 컨트롤 열림 / 눈 끔, CPU·메모리)를 그대로 PR 본문 `### Performance`에 붙여요.
   - 스크립트가 앱을 여러 번 껐다 켜고 미션 컨트롤을 열어요(약 7~10분). **사용자가 맥을 쓰는 중이면 돌리지 말고, 돌려도 되는지 먼저 물어봐요.**
   - 상황당 측정 시간은 `SECS`, 실행·전환 뒤 예열 시간은 `WARM`, 반복 횟수는 `ROUNDS`로 늘릴 수 있어요. 값이 흔들리면(다른 앱이 바쁠 때) 늘려서 다시 재요.
2. 창 드래그 경로(`mouseDragged`, `moveDragged`, `refreshGeometry` 등)를 건드렸으면 README의 '드래그 지연 측정'(`tools/testwin.swift`, `tools/lagstats.py`) 결과도 붙여요.
3. `main`보다 CPU가 0.3%p 넘게 늘면 원인을 찾아서 고치거나, 왜 감수하는지 PR 본문에 적어요. 노이즈인지 확인하려면 다시 재거나 `sample MacSnow 10`으로 프로파일해요.
4. README '리소스' 표의 수치를 바꾸는 변경이면 표도 같이 고쳐요.

## 그 밖에

- 빌드: `./build.sh` (Xcode 없이 Command Line Tools만). 실행 확인은 `./build.sh --run` 또는 `/Applications`에 설치한 앱으로 해요. 앱 사본이 여러 개 있으면 Spotlight가 엉뚱한 빌드를 열 수 있어요.
- 화면 캡처 없이 동작을 확인할 때는 `--showcase <dir>`(가상 화면 렌더링)과 `tools/notify.sh dump`를 써요.
- 사용자에게 보이는 기능을 바꾸면 README의 기능·메뉴 표도 같이 고쳐요.
