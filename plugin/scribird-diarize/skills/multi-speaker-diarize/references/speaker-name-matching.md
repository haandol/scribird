# 화자 이름 매칭

참석자 이름과 힌트는 로컬에서만 다룬다. AWS 작업에는 M4A와 화자 수·언어 설정만
전달하며, 이름이나 역할 정보는 업로드 파일과 AWS 명령에 넣지 않는다.

## 근거 우선순위

1. 화자가 직접 이름을 밝힌 자기소개
2. 제공받은 힌트와 한 사람에게만 일치하는 1인칭 역할·소속 진술
3. 여러 발화에서 반복되고 서로 모순되지 않는 고유한 1인칭 맥락

다른 화자가 이름을 부른 문장은 불린 사람의 발화가 아니므로 단독 근거로 사용하지 않는다.
참석자 목록 순서, AWS 라벨 번호, 최초 등장 순서, 발화량 순서도 신원 근거가 아니다.

직접적이고 모순 없는 근거나 사용자의 확인이 있으면 `verified`, 가능성만 있으면
`candidate`다. `candidate`는 실제 이름으로 적용되지 않고 `Unknown N`을 유지한다.

## 발화 모으기

첫 병합 뒤 다음처럼 소스와 AWS 라벨별 발화를 확인한다.

```bash
jq -s '
  sort_by(.source, .aws_label, .start)
  | group_by([.source, .aws_label])
  | map({
      source: .[0].source,
      aws_label: .[0].aws_label,
      utterances: map({start, text})
    })
' ~/Documents/Scribird/<세션>/transcript.speakers.jsonl
```

`aws_label`이 없는 발화는 이름 매칭 대상이 아니다.

## 로컬 계획 파일

세션 폴더의 `speaker-names.json`은 다음 구조를 쓴다.

```json
{
  "participants": {
    "remote": [
      {
        "name": "Alice",
        "hints": ["product manager", "introduces herself as Alice"]
      },
      {
        "name": "Bob",
        "hints": ["backend engineer"]
      }
    ]
  },
  "matches": {
    "remote": {
      "spk_0": {
        "name": "Alice",
        "status": "verified",
        "method": "self-identification",
        "evidence": [
          {
            "start": 12.3,
            "text": "Hi, I'm Alice."
          }
        ]
      },
      "spk_1": {
        "name": "Bob",
        "status": "candidate",
        "method": "conversation-context",
        "evidence": [
          {
            "start": 44.1,
            "text": "I own the backend deployment."
          }
        ]
      }
    }
  }
}
```

소스는 `remote`와 `me`, 상태는 `verified`와 `candidate`만 사용한다. 근거에는 세션 기준
시작 시각과 발화문을 하나 이상 넣는다. 한 소스에서 같은 실제 이름을 여러 AWS 라벨에
`verified`로 적용하지 않는다.

파일이나 일부 항목이 잘못돼도 병합은 실패하지 않는다. 사용할 수 있는 매칭만 적용되고,
나머지는 `Unknown N`으로 출력되며 문제 항목은 stderr와 리포트에 경고로 남는다.

## 사용자 확인

후보를 제시할 때는 이름, 원래 AWS 라벨, 근거 시각, 근거 발화를 함께 보여준다. 사용자가
확인하면 해당 항목을 `verified`로 바꾸고 같은 AWS 결과로 병합만 다시 실행한다. 새 업로드나
새 Transcribe 작업은 필요하지 않다.
