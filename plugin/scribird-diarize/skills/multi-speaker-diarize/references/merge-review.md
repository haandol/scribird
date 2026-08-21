# 화자 병합과 결과 검토

`aws-<source>.json`이 준비된 뒤 읽는다. 원본 `transcript.jsonl`은 수정하지 않는다.

## 1. 화자 경계를 병합한다

```bash
/usr/bin/python3 "$SKILL_DIR/scripts/merge_speakers.py" \
  --session ~/Documents/Scribird/<세션> \
  --aws-remote ~/Documents/Scribird/<세션>/aws-remote.json \
  --max-speakers 5
```

`me`도 승인받아 분석했다면 `--aws-me`를 함께 넘긴다. 이름을 아직 확정하지 못한 감지
화자는 `Unknown 1`부터 표시된다.

| 산출물 | 내용 |
|---|---|
| `transcript.speakers.md` | 세분화된 회의록. 본문은 로컬 전사, 차이는 각주 |
| `transcript.speakers.jsonl` | 원래 `source`와 AWS 라벨, 단어 차이 전량 |
| `diarization-report.md` | 배정률, 화자별 발화량, 오프셋, 차이와 경고 |

## 2. 필요할 때 실제 이름을 매칭한다

사용자가 참석자 이름을 제공했거나 실제 이름을 붙이려면 먼저
[speaker-name-matching.md](speaker-name-matching.md)를 읽는다. 직접 자기소개나 한
사람에게만 맞는 1인칭 역할·소속 진술처럼 화자 본인을 가리키는 근거를 사용한다.
근거가 약한 후보, 다른 사람이 이름을 부른 문장, 참석자 순서, AWS 라벨 순서,
발화량만으로 이름을 확정하지 않는다.

세션 폴더에 `speaker-names.json`을 만든 뒤 같은 AWS 결과로 다시 병합한다.

```bash
/usr/bin/python3 "$SKILL_DIR/scripts/merge_speakers.py" \
  --session ~/Documents/Scribird/<세션> \
  --aws-remote ~/Documents/Scribird/<세션>/aws-remote.json \
  --speaker-names ~/Documents/Scribird/<세션>/speaker-names.json \
  --max-speakers 5
```

이름 파일의 일부 항목이 누락되거나 충돌해도 병합은 계속된다. 경고가 난 항목만 검토하고,
적용되지 않은 화자가 `Unknown N`인지 확인한다. 실제 이름을 적용해도 원래 `source`와
`aws_label`은 보존한다.

## 3. 다음 순서로 검토한다

1. **정렬 의심 구간:** 서로 다른 발화를 비교했을 수 있으므로 그 구간의 단어 차이를
   판단에 쓰지 않는다. 오프셋을 확인하고 필요할 때만
   [thresholds.md](thresholds.md)의 시간 정렬 절차를 따른다.
2. **단어 차이:** `spacing_only` 또는 리포트의 `붙여쓰기만` 표시는 건너뛸 수 있다.
   나머지는 유사도 수치가 아니라 단어 자체를 읽고 뜻이 바뀌는지 판단한다. 불확실하면
   해당 시각의 원본 오디오 확인을 제안한다.
3. **전사 수정:** 본문은 로컬 전사를 유지한다. 의미가 바뀐 오인식을 찾으면 시각과
   차이를 제시하고 수정할지 사용자에게 묻는다.
4. **이름 근거:** 적용된 이름, 후보, 근거 발화, 원래 AWS 라벨을 확인한다. 근거가
   약하거나 모순되면 매칭을 제거하고 `Unknown N`으로 다시 병합한다.

## 4. 재실행 또는 진단 조건

- 감지 화자 수가 요청 상한과 같으면 사람이 더 있었을 수 있다. 상한을 올린 재실행을
  제안하되, 오디오를 다시 업로드하므로 새 승인을 받는다.
- 미배정이 30%를 넘거나 정렬 의심이 많으면 오프셋 또는 세션 짝이 잘못됐을 수 있다.
  [thresholds.md](thresholds.md)를 읽고 진단한다.
- AWS 오류, 남은 S3 객체, 배정률 0%, 이름 경고 등 증상이 있으면
  [troubleshooting.md](troubleshooting.md)를 읽는다.
