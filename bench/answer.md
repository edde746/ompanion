## Section 0: reading the session file

The run directory for session 0 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 1 has **bold text**, *emphasis*, `inline_code_1()` and a [link to item 1](https://example.com/items/1). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 7 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 2.1: check `step_1` and record the result in **run 2**
- Item 2.2: check `step_2` and record the result in **run 2**
- Item 2.3: check `step_3` and record the result in **run 2**
- Item 2.4: check `step_4` and record the result in **run 2**
- Item 2.5: check `step_5` and record the result in **run 2**

```dart
/// Block 3.
Future<int> handle3(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 3;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 4.1 | `os-1` | 41 | **pass** |
| 4.2 | `os-2` | 42 | **pass** |
| 4.3 | `os-3` | 43 | **pass** |
| 4.4 | `os-4` | 44 | **pass** |
| 4.5 | `os-5` | 45 | **pass** |
| 4.6 | `os-6` | 46 | **pass** |

Math in block 5: the inline term $a_{5} + b^2 = c_{5}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{5} k^2 = \frac{5(5+1)(2 \cdot 5+1)}{6}$$

## Section 6: reading the session file

The run directory for session 6 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 7 has **bold text**, *emphasis*, `inline_code_7()` and a [link to item 7](https://example.com/items/7). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 49 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 8.1: check `step_1` and record the result in **run 8**
- Item 8.2: check `step_2` and record the result in **run 8**
- Item 8.3: check `step_3` and record the result in **run 8**
- Item 8.4: check `step_4` and record the result in **run 8**
- Item 8.5: check `step_5` and record the result in **run 8**

```dart
/// Block 9.
Future<int> handle9(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 9;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 10.1 | `os-1` | 101 | **pass** |
| 10.2 | `os-2` | 102 | **pass** |
| 10.3 | `os-3` | 103 | **pass** |
| 10.4 | `os-4` | 104 | **pass** |
| 10.5 | `os-5` | 105 | **pass** |
| 10.6 | `os-6` | 106 | **pass** |

Math in block 11: the inline term $a_{11} + b^2 = c_{11}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{11} k^2 = \frac{11(11+1)(2 \cdot 11+1)}{6}$$

## Section 12: reading the session file

The run directory for session 12 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 13 has **bold text**, *emphasis*, `inline_code_13()` and a [link to item 13](https://example.com/items/13). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 91 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 14.1: check `step_1` and record the result in **run 14**
- Item 14.2: check `step_2` and record the result in **run 14**
- Item 14.3: check `step_3` and record the result in **run 14**
- Item 14.4: check `step_4` and record the result in **run 14**
- Item 14.5: check `step_5` and record the result in **run 14**

```dart
/// Block 15.
Future<int> handle15(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 15;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 16.1 | `os-1` | 161 | **pass** |
| 16.2 | `os-2` | 162 | **pass** |
| 16.3 | `os-3` | 163 | **pass** |
| 16.4 | `os-4` | 164 | **pass** |
| 16.5 | `os-5` | 165 | **pass** |
| 16.6 | `os-6` | 166 | **pass** |

Math in block 17: the inline term $a_{17} + b^2 = c_{17}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{17} k^2 = \frac{17(17+1)(2 \cdot 17+1)}{6}$$

## Section 18: reading the session file

The run directory for session 18 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 19 has **bold text**, *emphasis*, `inline_code_19()` and a [link to item 19](https://example.com/items/19). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 133 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 20.1: check `step_1` and record the result in **run 20**
- Item 20.2: check `step_2` and record the result in **run 20**
- Item 20.3: check `step_3` and record the result in **run 20**
- Item 20.4: check `step_4` and record the result in **run 20**
- Item 20.5: check `step_5` and record the result in **run 20**

```dart
/// Block 21.
Future<int> handle21(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 21;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 22.1 | `os-1` | 221 | **pass** |
| 22.2 | `os-2` | 222 | **pass** |
| 22.3 | `os-3` | 223 | **pass** |
| 22.4 | `os-4` | 224 | **pass** |
| 22.5 | `os-5` | 225 | **pass** |
| 22.6 | `os-6` | 226 | **pass** |

Math in block 23: the inline term $a_{23} + b^2 = c_{23}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{23} k^2 = \frac{23(23+1)(2 \cdot 23+1)}{6}$$

## Section 24: reading the session file

The run directory for session 24 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 25 has **bold text**, *emphasis*, `inline_code_25()` and a [link to item 25](https://example.com/items/25). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 175 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 26.1: check `step_1` and record the result in **run 26**
- Item 26.2: check `step_2` and record the result in **run 26**
- Item 26.3: check `step_3` and record the result in **run 26**
- Item 26.4: check `step_4` and record the result in **run 26**
- Item 26.5: check `step_5` and record the result in **run 26**

```dart
/// Block 27.
Future<int> handle27(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 27;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 28.1 | `os-1` | 281 | **pass** |
| 28.2 | `os-2` | 282 | **pass** |
| 28.3 | `os-3` | 283 | **pass** |
| 28.4 | `os-4` | 284 | **pass** |
| 28.5 | `os-5` | 285 | **pass** |
| 28.6 | `os-6` | 286 | **pass** |

Math in block 29: the inline term $a_{29} + b^2 = c_{29}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{29} k^2 = \frac{29(29+1)(2 \cdot 29+1)}{6}$$

## Section 30: reading the session file

The run directory for session 30 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 31 has **bold text**, *emphasis*, `inline_code_31()` and a [link to item 31](https://example.com/items/31). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 217 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 32.1: check `step_1` and record the result in **run 32**
- Item 32.2: check `step_2` and record the result in **run 32**
- Item 32.3: check `step_3` and record the result in **run 32**
- Item 32.4: check `step_4` and record the result in **run 32**
- Item 32.5: check `step_5` and record the result in **run 32**

```dart
/// Block 33.
Future<int> handle33(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 33;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 34.1 | `os-1` | 341 | **pass** |
| 34.2 | `os-2` | 342 | **pass** |
| 34.3 | `os-3` | 343 | **pass** |
| 34.4 | `os-4` | 344 | **pass** |
| 34.5 | `os-5` | 345 | **pass** |
| 34.6 | `os-6` | 346 | **pass** |

Math in block 35: the inline term $a_{35} + b^2 = c_{35}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{35} k^2 = \frac{35(35+1)(2 \cdot 35+1)}{6}$$

## Section 36: reading the session file

The run directory for session 36 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 37 has **bold text**, *emphasis*, `inline_code_37()` and a [link to item 37](https://example.com/items/37). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 259 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 38.1: check `step_1` and record the result in **run 38**
- Item 38.2: check `step_2` and record the result in **run 38**
- Item 38.3: check `step_3` and record the result in **run 38**
- Item 38.4: check `step_4` and record the result in **run 38**
- Item 38.5: check `step_5` and record the result in **run 38**

```dart
/// Block 39.
Future<int> handle39(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 39;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 40.1 | `os-1` | 401 | **pass** |
| 40.2 | `os-2` | 402 | **pass** |
| 40.3 | `os-3` | 403 | **pass** |
| 40.4 | `os-4` | 404 | **pass** |
| 40.5 | `os-5` | 405 | **pass** |
| 40.6 | `os-6` | 406 | **pass** |

Math in block 41: the inline term $a_{41} + b^2 = c_{41}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{41} k^2 = \frac{41(41+1)(2 \cdot 41+1)}{6}$$

## Section 42: reading the session file

The run directory for session 42 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 43 has **bold text**, *emphasis*, `inline_code_43()` and a [link to item 43](https://example.com/items/43). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 301 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 44.1: check `step_1` and record the result in **run 44**
- Item 44.2: check `step_2` and record the result in **run 44**
- Item 44.3: check `step_3` and record the result in **run 44**
- Item 44.4: check `step_4` and record the result in **run 44**
- Item 44.5: check `step_5` and record the result in **run 44**

```dart
/// Block 45.
Future<int> handle45(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 45;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 46.1 | `os-1` | 461 | **pass** |
| 46.2 | `os-2` | 462 | **pass** |
| 46.3 | `os-3` | 463 | **pass** |
| 46.4 | `os-4` | 464 | **pass** |
| 46.5 | `os-5` | 465 | **pass** |
| 46.6 | `os-6` | 466 | **pass** |

Math in block 47: the inline term $a_{47} + b^2 = c_{47}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{47} k^2 = \frac{47(47+1)(2 \cdot 47+1)}{6}$$

## Section 48: reading the session file

The run directory for session 48 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 49 has **bold text**, *emphasis*, `inline_code_49()` and a [link to item 49](https://example.com/items/49). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 343 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 50.1: check `step_1` and record the result in **run 50**
- Item 50.2: check `step_2` and record the result in **run 50**
- Item 50.3: check `step_3` and record the result in **run 50**
- Item 50.4: check `step_4` and record the result in **run 50**
- Item 50.5: check `step_5` and record the result in **run 50**

```dart
/// Block 51.
Future<int> handle51(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 51;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 52.1 | `os-1` | 521 | **pass** |
| 52.2 | `os-2` | 522 | **pass** |
| 52.3 | `os-3` | 523 | **pass** |
| 52.4 | `os-4` | 524 | **pass** |
| 52.5 | `os-5` | 525 | **pass** |
| 52.6 | `os-6` | 526 | **pass** |

Math in block 53: the inline term $a_{53} + b^2 = c_{53}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{53} k^2 = \frac{53(53+1)(2 \cdot 53+1)}{6}$$

## Section 54: reading the session file

The run directory for session 54 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 55 has **bold text**, *emphasis*, `inline_code_55()` and a [link to item 55](https://example.com/items/55). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 385 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 56.1: check `step_1` and record the result in **run 56**
- Item 56.2: check `step_2` and record the result in **run 56**
- Item 56.3: check `step_3` and record the result in **run 56**
- Item 56.4: check `step_4` and record the result in **run 56**
- Item 56.5: check `step_5` and record the result in **run 56**

```dart
/// Block 57.
Future<int> handle57(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 57;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 58.1 | `os-1` | 581 | **pass** |
| 58.2 | `os-2` | 582 | **pass** |
| 58.3 | `os-3` | 583 | **pass** |
| 58.4 | `os-4` | 584 | **pass** |
| 58.5 | `os-5` | 585 | **pass** |
| 58.6 | `os-6` | 586 | **pass** |

Math in block 59: the inline term $a_{59} + b^2 = c_{59}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{59} k^2 = \frac{59(59+1)(2 \cdot 59+1)}{6}$$

## Section 60: reading the session file

The run directory for session 60 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 61 has **bold text**, *emphasis*, `inline_code_61()` and a [link to item 61](https://example.com/items/61). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 427 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 62.1: check `step_1` and record the result in **run 62**
- Item 62.2: check `step_2` and record the result in **run 62**
- Item 62.3: check `step_3` and record the result in **run 62**
- Item 62.4: check `step_4` and record the result in **run 62**
- Item 62.5: check `step_5` and record the result in **run 62**

```dart
/// Block 63.
Future<int> handle63(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 63;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 64.1 | `os-1` | 641 | **pass** |
| 64.2 | `os-2` | 642 | **pass** |
| 64.3 | `os-3` | 643 | **pass** |
| 64.4 | `os-4` | 644 | **pass** |
| 64.5 | `os-5` | 645 | **pass** |
| 64.6 | `os-6` | 646 | **pass** |

Math in block 65: the inline term $a_{65} + b^2 = c_{65}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{65} k^2 = \frac{65(65+1)(2 \cdot 65+1)}{6}$$

## Section 66: reading the session file

The run directory for session 66 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 67 has **bold text**, *emphasis*, `inline_code_67()` and a [link to item 67](https://example.com/items/67). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 469 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 68.1: check `step_1` and record the result in **run 68**
- Item 68.2: check `step_2` and record the result in **run 68**
- Item 68.3: check `step_3` and record the result in **run 68**
- Item 68.4: check `step_4` and record the result in **run 68**
- Item 68.5: check `step_5` and record the result in **run 68**

```dart
/// Block 69.
Future<int> handle69(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 69;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 70.1 | `os-1` | 701 | **pass** |
| 70.2 | `os-2` | 702 | **pass** |
| 70.3 | `os-3` | 703 | **pass** |
| 70.4 | `os-4` | 704 | **pass** |
| 70.5 | `os-5` | 705 | **pass** |
| 70.6 | `os-6` | 706 | **pass** |

Math in block 71: the inline term $a_{71} + b^2 = c_{71}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{71} k^2 = \frac{71(71+1)(2 \cdot 71+1)}{6}$$

## Section 72: reading the session file

The run directory for session 72 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 73 has **bold text**, *emphasis*, `inline_code_73()` and a [link to item 73](https://example.com/items/73). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 511 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 74.1: check `step_1` and record the result in **run 74**
- Item 74.2: check `step_2` and record the result in **run 74**
- Item 74.3: check `step_3` and record the result in **run 74**
- Item 74.4: check `step_4` and record the result in **run 74**
- Item 74.5: check `step_5` and record the result in **run 74**

```dart
/// Block 75.
Future<int> handle75(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 75;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 76.1 | `os-1` | 761 | **pass** |
| 76.2 | `os-2` | 762 | **pass** |
| 76.3 | `os-3` | 763 | **pass** |
| 76.4 | `os-4` | 764 | **pass** |
| 76.5 | `os-5` | 765 | **pass** |
| 76.6 | `os-6` | 766 | **pass** |

Math in block 77: the inline term $a_{77} + b^2 = c_{77}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{77} k^2 = \frac{77(77+1)(2 \cdot 77+1)}{6}$$

## Section 78: reading the session file

The run directory for session 78 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 79 has **bold text**, *emphasis*, `inline_code_79()` and a [link to item 79](https://example.com/items/79). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 553 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 80.1: check `step_1` and record the result in **run 80**
- Item 80.2: check `step_2` and record the result in **run 80**
- Item 80.3: check `step_3` and record the result in **run 80**
- Item 80.4: check `step_4` and record the result in **run 80**
- Item 80.5: check `step_5` and record the result in **run 80**

```dart
/// Block 81.
Future<int> handle81(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 81;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 82.1 | `os-1` | 821 | **pass** |
| 82.2 | `os-2` | 822 | **pass** |
| 82.3 | `os-3` | 823 | **pass** |
| 82.4 | `os-4` | 824 | **pass** |
| 82.5 | `os-5` | 825 | **pass** |
| 82.6 | `os-6` | 826 | **pass** |

Math in block 83: the inline term $a_{83} + b^2 = c_{83}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{83} k^2 = \frac{83(83+1)(2 \cdot 83+1)}{6}$$

## Section 84: reading the session file

The run directory for session 84 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 85 has **bold text**, *emphasis*, `inline_code_85()` and a [link to item 85](https://example.com/items/85). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 595 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 86.1: check `step_1` and record the result in **run 86**
- Item 86.2: check `step_2` and record the result in **run 86**
- Item 86.3: check `step_3` and record the result in **run 86**
- Item 86.4: check `step_4` and record the result in **run 86**
- Item 86.5: check `step_5` and record the result in **run 86**

```dart
/// Block 87.
Future<int> handle87(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 87;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 88.1 | `os-1` | 881 | **pass** |
| 88.2 | `os-2` | 882 | **pass** |
| 88.3 | `os-3` | 883 | **pass** |
| 88.4 | `os-4` | 884 | **pass** |
| 88.5 | `os-5` | 885 | **pass** |
| 88.6 | `os-6` | 886 | **pass** |

Math in block 89: the inline term $a_{89} + b^2 = c_{89}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{89} k^2 = \frac{89(89+1)(2 \cdot 89+1)}{6}$$

## Section 90: reading the session file

The run directory for session 90 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 91 has **bold text**, *emphasis*, `inline_code_91()` and a [link to item 91](https://example.com/items/91). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 637 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 92.1: check `step_1` and record the result in **run 92**
- Item 92.2: check `step_2` and record the result in **run 92**
- Item 92.3: check `step_3` and record the result in **run 92**
- Item 92.4: check `step_4` and record the result in **run 92**
- Item 92.5: check `step_5` and record the result in **run 92**

```dart
/// Block 93.
Future<int> handle93(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 93;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 94.1 | `os-1` | 941 | **pass** |
| 94.2 | `os-2` | 942 | **pass** |
| 94.3 | `os-3` | 943 | **pass** |
| 94.4 | `os-4` | 944 | **pass** |
| 94.5 | `os-5` | 945 | **pass** |
| 94.6 | `os-6` | 946 | **pass** |

Math in block 95: the inline term $a_{95} + b^2 = c_{95}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{95} k^2 = \frac{95(95+1)(2 \cdot 95+1)}{6}$$

## Section 96: reading the session file

The run directory for session 96 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 97 has **bold text**, *emphasis*, `inline_code_97()` and a [link to item 97](https://example.com/items/97). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 679 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 98.1: check `step_1` and record the result in **run 98**
- Item 98.2: check `step_2` and record the result in **run 98**
- Item 98.3: check `step_3` and record the result in **run 98**
- Item 98.4: check `step_4` and record the result in **run 98**
- Item 98.5: check `step_5` and record the result in **run 98**

```dart
/// Block 99.
Future<int> handle99(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 99;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 100.1 | `os-1` | 1001 | **pass** |
| 100.2 | `os-2` | 1002 | **pass** |
| 100.3 | `os-3` | 1003 | **pass** |
| 100.4 | `os-4` | 1004 | **pass** |
| 100.5 | `os-5` | 1005 | **pass** |
| 100.6 | `os-6` | 1006 | **pass** |

Math in block 101: the inline term $a_{101} + b^2 = c_{101}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{101} k^2 = \frac{101(101+1)(2 \cdot 101+1)}{6}$$

## Section 102: reading the session file

The run directory for session 102 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 103 has **bold text**, *emphasis*, `inline_code_103()` and a [link to item 103](https://example.com/items/103). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 721 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 104.1: check `step_1` and record the result in **run 104**
- Item 104.2: check `step_2` and record the result in **run 104**
- Item 104.3: check `step_3` and record the result in **run 104**
- Item 104.4: check `step_4` and record the result in **run 104**
- Item 104.5: check `step_5` and record the result in **run 104**

```dart
/// Block 105.
Future<int> handle105(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 105;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 106.1 | `os-1` | 1061 | **pass** |
| 106.2 | `os-2` | 1062 | **pass** |
| 106.3 | `os-3` | 1063 | **pass** |
| 106.4 | `os-4` | 1064 | **pass** |
| 106.5 | `os-5` | 1065 | **pass** |
| 106.6 | `os-6` | 1066 | **pass** |

Math in block 107: the inline term $a_{107} + b^2 = c_{107}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{107} k^2 = \frac{107(107+1)(2 \cdot 107+1)}{6}$$

## Section 108: reading the session file

The run directory for session 108 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 109 has **bold text**, *emphasis*, `inline_code_109()` and a [link to item 109](https://example.com/items/109). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 763 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 110.1: check `step_1` and record the result in **run 110**
- Item 110.2: check `step_2` and record the result in **run 110**
- Item 110.3: check `step_3` and record the result in **run 110**
- Item 110.4: check `step_4` and record the result in **run 110**
- Item 110.5: check `step_5` and record the result in **run 110**

```dart
/// Block 111.
Future<int> handle111(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 111;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 112.1 | `os-1` | 1121 | **pass** |
| 112.2 | `os-2` | 1122 | **pass** |
| 112.3 | `os-3` | 1123 | **pass** |
| 112.4 | `os-4` | 1124 | **pass** |
| 112.5 | `os-5` | 1125 | **pass** |
| 112.6 | `os-6` | 1126 | **pass** |

Math in block 113: the inline term $a_{113} + b^2 = c_{113}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{113} k^2 = \frac{113(113+1)(2 \cdot 113+1)}{6}$$

## Section 114: reading the session file

The run directory for session 114 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 115 has **bold text**, *emphasis*, `inline_code_115()` and a [link to item 115](https://example.com/items/115). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 805 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 116.1: check `step_1` and record the result in **run 116**
- Item 116.2: check `step_2` and record the result in **run 116**
- Item 116.3: check `step_3` and record the result in **run 116**
- Item 116.4: check `step_4` and record the result in **run 116**
- Item 116.5: check `step_5` and record the result in **run 116**

```dart
/// Block 117.
Future<int> handle117(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 117;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 118.1 | `os-1` | 1181 | **pass** |
| 118.2 | `os-2` | 1182 | **pass** |
| 118.3 | `os-3` | 1183 | **pass** |
| 118.4 | `os-4` | 1184 | **pass** |
| 118.5 | `os-5` | 1185 | **pass** |
| 118.6 | `os-6` | 1186 | **pass** |

Math in block 119: the inline term $a_{119} + b^2 = c_{119}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{119} k^2 = \frac{119(119+1)(2 \cdot 119+1)}{6}$$

## Section 120: reading the session file

The run directory for session 120 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 121 has **bold text**, *emphasis*, `inline_code_121()` and a [link to item 121](https://example.com/items/121). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 847 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 122.1: check `step_1` and record the result in **run 122**
- Item 122.2: check `step_2` and record the result in **run 122**
- Item 122.3: check `step_3` and record the result in **run 122**
- Item 122.4: check `step_4` and record the result in **run 122**
- Item 122.5: check `step_5` and record the result in **run 122**

```dart
/// Block 123.
Future<int> handle123(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 123;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 124.1 | `os-1` | 1241 | **pass** |
| 124.2 | `os-2` | 1242 | **pass** |
| 124.3 | `os-3` | 1243 | **pass** |
| 124.4 | `os-4` | 1244 | **pass** |
| 124.5 | `os-5` | 1245 | **pass** |
| 124.6 | `os-6` | 1246 | **pass** |

Math in block 125: the inline term $a_{125} + b^2 = c_{125}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{125} k^2 = \frac{125(125+1)(2 \cdot 125+1)}{6}$$

## Section 126: reading the session file

The run directory for session 126 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 127 has **bold text**, *emphasis*, `inline_code_127()` and a [link to item 127](https://example.com/items/127). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 889 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 128.1: check `step_1` and record the result in **run 128**
- Item 128.2: check `step_2` and record the result in **run 128**
- Item 128.3: check `step_3` and record the result in **run 128**
- Item 128.4: check `step_4` and record the result in **run 128**
- Item 128.5: check `step_5` and record the result in **run 128**

```dart
/// Block 129.
Future<int> handle129(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 129;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 130.1 | `os-1` | 1301 | **pass** |
| 130.2 | `os-2` | 1302 | **pass** |
| 130.3 | `os-3` | 1303 | **pass** |
| 130.4 | `os-4` | 1304 | **pass** |
| 130.5 | `os-5` | 1305 | **pass** |
| 130.6 | `os-6` | 1306 | **pass** |

Math in block 131: the inline term $a_{131} + b^2 = c_{131}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{131} k^2 = \frac{131(131+1)(2 \cdot 131+1)}{6}$$

## Section 132: reading the session file

The run directory for session 132 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 133 has **bold text**, *emphasis*, `inline_code_133()` and a [link to item 133](https://example.com/items/133). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 931 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 134.1: check `step_1` and record the result in **run 134**
- Item 134.2: check `step_2` and record the result in **run 134**
- Item 134.3: check `step_3` and record the result in **run 134**
- Item 134.4: check `step_4` and record the result in **run 134**
- Item 134.5: check `step_5` and record the result in **run 134**

```dart
/// Block 135.
Future<int> handle135(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 135;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 136.1 | `os-1` | 1361 | **pass** |
| 136.2 | `os-2` | 1362 | **pass** |
| 136.3 | `os-3` | 1363 | **pass** |
| 136.4 | `os-4` | 1364 | **pass** |
| 136.5 | `os-5` | 1365 | **pass** |
| 136.6 | `os-6` | 1366 | **pass** |

Math in block 137: the inline term $a_{137} + b^2 = c_{137}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{137} k^2 = \frac{137(137+1)(2 \cdot 137+1)}{6}$$

## Section 138: reading the session file

The run directory for session 138 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 139 has **bold text**, *emphasis*, `inline_code_139()` and a [link to item 139](https://example.com/items/139). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 973 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 140.1: check `step_1` and record the result in **run 140**
- Item 140.2: check `step_2` and record the result in **run 140**
- Item 140.3: check `step_3` and record the result in **run 140**
- Item 140.4: check `step_4` and record the result in **run 140**
- Item 140.5: check `step_5` and record the result in **run 140**

```dart
/// Block 141.
Future<int> handle141(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 141;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 142.1 | `os-1` | 1421 | **pass** |
| 142.2 | `os-2` | 1422 | **pass** |
| 142.3 | `os-3` | 1423 | **pass** |
| 142.4 | `os-4` | 1424 | **pass** |
| 142.5 | `os-5` | 1425 | **pass** |
| 142.6 | `os-6` | 1426 | **pass** |

Math in block 143: the inline term $a_{143} + b^2 = c_{143}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{143} k^2 = \frac{143(143+1)(2 \cdot 143+1)}{6}$$

## Section 144: reading the session file

The run directory for session 144 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 145 has **bold text**, *emphasis*, `inline_code_145()` and a [link to item 145](https://example.com/items/145). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1015 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 146.1: check `step_1` and record the result in **run 146**
- Item 146.2: check `step_2` and record the result in **run 146**
- Item 146.3: check `step_3` and record the result in **run 146**
- Item 146.4: check `step_4` and record the result in **run 146**
- Item 146.5: check `step_5` and record the result in **run 146**

```dart
/// Block 147.
Future<int> handle147(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 147;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 148.1 | `os-1` | 1481 | **pass** |
| 148.2 | `os-2` | 1482 | **pass** |
| 148.3 | `os-3` | 1483 | **pass** |
| 148.4 | `os-4` | 1484 | **pass** |
| 148.5 | `os-5` | 1485 | **pass** |
| 148.6 | `os-6` | 1486 | **pass** |

Math in block 149: the inline term $a_{149} + b^2 = c_{149}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{149} k^2 = \frac{149(149+1)(2 \cdot 149+1)}{6}$$

## Section 150: reading the session file

The run directory for session 150 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 151 has **bold text**, *emphasis*, `inline_code_151()` and a [link to item 151](https://example.com/items/151). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1057 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 152.1: check `step_1` and record the result in **run 152**
- Item 152.2: check `step_2` and record the result in **run 152**
- Item 152.3: check `step_3` and record the result in **run 152**
- Item 152.4: check `step_4` and record the result in **run 152**
- Item 152.5: check `step_5` and record the result in **run 152**

```dart
/// Block 153.
Future<int> handle153(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 153;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 154.1 | `os-1` | 1541 | **pass** |
| 154.2 | `os-2` | 1542 | **pass** |
| 154.3 | `os-3` | 1543 | **pass** |
| 154.4 | `os-4` | 1544 | **pass** |
| 154.5 | `os-5` | 1545 | **pass** |
| 154.6 | `os-6` | 1546 | **pass** |

Math in block 155: the inline term $a_{155} + b^2 = c_{155}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{155} k^2 = \frac{155(155+1)(2 \cdot 155+1)}{6}$$

## Section 156: reading the session file

The run directory for session 156 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 157 has **bold text**, *emphasis*, `inline_code_157()` and a [link to item 157](https://example.com/items/157). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1099 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 158.1: check `step_1` and record the result in **run 158**
- Item 158.2: check `step_2` and record the result in **run 158**
- Item 158.3: check `step_3` and record the result in **run 158**
- Item 158.4: check `step_4` and record the result in **run 158**
- Item 158.5: check `step_5` and record the result in **run 158**

```dart
/// Block 159.
Future<int> handle159(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 159;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 160.1 | `os-1` | 1601 | **pass** |
| 160.2 | `os-2` | 1602 | **pass** |
| 160.3 | `os-3` | 1603 | **pass** |
| 160.4 | `os-4` | 1604 | **pass** |
| 160.5 | `os-5` | 1605 | **pass** |
| 160.6 | `os-6` | 1606 | **pass** |

Math in block 161: the inline term $a_{161} + b^2 = c_{161}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{161} k^2 = \frac{161(161+1)(2 \cdot 161+1)}{6}$$

## Section 162: reading the session file

The run directory for session 162 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 163 has **bold text**, *emphasis*, `inline_code_163()` and a [link to item 163](https://example.com/items/163). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1141 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 164.1: check `step_1` and record the result in **run 164**
- Item 164.2: check `step_2` and record the result in **run 164**
- Item 164.3: check `step_3` and record the result in **run 164**
- Item 164.4: check `step_4` and record the result in **run 164**
- Item 164.5: check `step_5` and record the result in **run 164**

```dart
/// Block 165.
Future<int> handle165(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 165;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 166.1 | `os-1` | 1661 | **pass** |
| 166.2 | `os-2` | 1662 | **pass** |
| 166.3 | `os-3` | 1663 | **pass** |
| 166.4 | `os-4` | 1664 | **pass** |
| 166.5 | `os-5` | 1665 | **pass** |
| 166.6 | `os-6` | 1666 | **pass** |

Math in block 167: the inline term $a_{167} + b^2 = c_{167}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{167} k^2 = \frac{167(167+1)(2 \cdot 167+1)}{6}$$

## Section 168: reading the session file

The run directory for session 168 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 169 has **bold text**, *emphasis*, `inline_code_169()` and a [link to item 169](https://example.com/items/169). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1183 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 170.1: check `step_1` and record the result in **run 170**
- Item 170.2: check `step_2` and record the result in **run 170**
- Item 170.3: check `step_3` and record the result in **run 170**
- Item 170.4: check `step_4` and record the result in **run 170**
- Item 170.5: check `step_5` and record the result in **run 170**

```dart
/// Block 171.
Future<int> handle171(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 171;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 172.1 | `os-1` | 1721 | **pass** |
| 172.2 | `os-2` | 1722 | **pass** |
| 172.3 | `os-3` | 1723 | **pass** |
| 172.4 | `os-4` | 1724 | **pass** |
| 172.5 | `os-5` | 1725 | **pass** |
| 172.6 | `os-6` | 1726 | **pass** |

Math in block 173: the inline term $a_{173} + b^2 = c_{173}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{173} k^2 = \frac{173(173+1)(2 \cdot 173+1)}{6}$$

## Section 174: reading the session file

The run directory for session 174 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 175 has **bold text**, *emphasis*, `inline_code_175()` and a [link to item 175](https://example.com/items/175). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1225 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 176.1: check `step_1` and record the result in **run 176**
- Item 176.2: check `step_2` and record the result in **run 176**
- Item 176.3: check `step_3` and record the result in **run 176**
- Item 176.4: check `step_4` and record the result in **run 176**
- Item 176.5: check `step_5` and record the result in **run 176**

```dart
/// Block 177.
Future<int> handle177(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 177;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 178.1 | `os-1` | 1781 | **pass** |
| 178.2 | `os-2` | 1782 | **pass** |
| 178.3 | `os-3` | 1783 | **pass** |
| 178.4 | `os-4` | 1784 | **pass** |
| 178.5 | `os-5` | 1785 | **pass** |
| 178.6 | `os-6` | 1786 | **pass** |

Math in block 179: the inline term $a_{179} + b^2 = c_{179}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{179} k^2 = \frac{179(179+1)(2 \cdot 179+1)}{6}$$

## Section 180: reading the session file

The run directory for session 180 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 181 has **bold text**, *emphasis*, `inline_code_181()` and a [link to item 181](https://example.com/items/181). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1267 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 182.1: check `step_1` and record the result in **run 182**
- Item 182.2: check `step_2` and record the result in **run 182**
- Item 182.3: check `step_3` and record the result in **run 182**
- Item 182.4: check `step_4` and record the result in **run 182**
- Item 182.5: check `step_5` and record the result in **run 182**

```dart
/// Block 183.
Future<int> handle183(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 183;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 184.1 | `os-1` | 1841 | **pass** |
| 184.2 | `os-2` | 1842 | **pass** |
| 184.3 | `os-3` | 1843 | **pass** |
| 184.4 | `os-4` | 1844 | **pass** |
| 184.5 | `os-5` | 1845 | **pass** |
| 184.6 | `os-6` | 1846 | **pass** |

Math in block 185: the inline term $a_{185} + b^2 = c_{185}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{185} k^2 = \frac{185(185+1)(2 \cdot 185+1)}{6}$$

## Section 186: reading the session file

The run directory for session 186 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 187 has **bold text**, *emphasis*, `inline_code_187()` and a [link to item 187](https://example.com/items/187). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1309 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 188.1: check `step_1` and record the result in **run 188**
- Item 188.2: check `step_2` and record the result in **run 188**
- Item 188.3: check `step_3` and record the result in **run 188**
- Item 188.4: check `step_4` and record the result in **run 188**
- Item 188.5: check `step_5` and record the result in **run 188**

```dart
/// Block 189.
Future<int> handle189(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 189;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 190.1 | `os-1` | 1901 | **pass** |
| 190.2 | `os-2` | 1902 | **pass** |
| 190.3 | `os-3` | 1903 | **pass** |
| 190.4 | `os-4` | 1904 | **pass** |
| 190.5 | `os-5` | 1905 | **pass** |
| 190.6 | `os-6` | 1906 | **pass** |

Math in block 191: the inline term $a_{191} + b^2 = c_{191}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{191} k^2 = \frac{191(191+1)(2 \cdot 191+1)}{6}$$

## Section 192: reading the session file

The run directory for session 192 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 193 has **bold text**, *emphasis*, `inline_code_193()` and a [link to item 193](https://example.com/items/193). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1351 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 194.1: check `step_1` and record the result in **run 194**
- Item 194.2: check `step_2` and record the result in **run 194**
- Item 194.3: check `step_3` and record the result in **run 194**
- Item 194.4: check `step_4` and record the result in **run 194**
- Item 194.5: check `step_5` and record the result in **run 194**

```dart
/// Block 195.
Future<int> handle195(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 195;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 196.1 | `os-1` | 1961 | **pass** |
| 196.2 | `os-2` | 1962 | **pass** |
| 196.3 | `os-3` | 1963 | **pass** |
| 196.4 | `os-4` | 1964 | **pass** |
| 196.5 | `os-5` | 1965 | **pass** |
| 196.6 | `os-6` | 1966 | **pass** |

Math in block 197: the inline term $a_{197} + b^2 = c_{197}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{197} k^2 = \frac{197(197+1)(2 \cdot 197+1)}{6}$$

## Section 198: reading the session file

The run directory for session 198 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 199 has **bold text**, *emphasis*, `inline_code_199()` and a [link to item 199](https://example.com/items/199). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1393 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 200.1: check `step_1` and record the result in **run 200**
- Item 200.2: check `step_2` and record the result in **run 200**
- Item 200.3: check `step_3` and record the result in **run 200**
- Item 200.4: check `step_4` and record the result in **run 200**
- Item 200.5: check `step_5` and record the result in **run 200**

```dart
/// Block 201.
Future<int> handle201(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 201;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 202.1 | `os-1` | 2021 | **pass** |
| 202.2 | `os-2` | 2022 | **pass** |
| 202.3 | `os-3` | 2023 | **pass** |
| 202.4 | `os-4` | 2024 | **pass** |
| 202.5 | `os-5` | 2025 | **pass** |
| 202.6 | `os-6` | 2026 | **pass** |

Math in block 203: the inline term $a_{203} + b^2 = c_{203}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{203} k^2 = \frac{203(203+1)(2 \cdot 203+1)}{6}$$

## Section 204: reading the session file

The run directory for session 204 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 205 has **bold text**, *emphasis*, `inline_code_205()` and a [link to item 205](https://example.com/items/205). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1435 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 206.1: check `step_1` and record the result in **run 206**
- Item 206.2: check `step_2` and record the result in **run 206**
- Item 206.3: check `step_3` and record the result in **run 206**
- Item 206.4: check `step_4` and record the result in **run 206**
- Item 206.5: check `step_5` and record the result in **run 206**

```dart
/// Block 207.
Future<int> handle207(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 207;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 208.1 | `os-1` | 2081 | **pass** |
| 208.2 | `os-2` | 2082 | **pass** |
| 208.3 | `os-3` | 2083 | **pass** |
| 208.4 | `os-4` | 2084 | **pass** |
| 208.5 | `os-5` | 2085 | **pass** |
| 208.6 | `os-6` | 2086 | **pass** |

Math in block 209: the inline term $a_{209} + b^2 = c_{209}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{209} k^2 = \frac{209(209+1)(2 \cdot 209+1)}{6}$$

## Section 210: reading the session file

The run directory for session 210 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 211 has **bold text**, *emphasis*, `inline_code_211()` and a [link to item 211](https://example.com/items/211). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1477 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 212.1: check `step_1` and record the result in **run 212**
- Item 212.2: check `step_2` and record the result in **run 212**
- Item 212.3: check `step_3` and record the result in **run 212**
- Item 212.4: check `step_4` and record the result in **run 212**
- Item 212.5: check `step_5` and record the result in **run 212**

```dart
/// Block 213.
Future<int> handle213(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 213;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 214.1 | `os-1` | 2141 | **pass** |
| 214.2 | `os-2` | 2142 | **pass** |
| 214.3 | `os-3` | 2143 | **pass** |
| 214.4 | `os-4` | 2144 | **pass** |
| 214.5 | `os-5` | 2145 | **pass** |
| 214.6 | `os-6` | 2146 | **pass** |

Math in block 215: the inline term $a_{215} + b^2 = c_{215}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{215} k^2 = \frac{215(215+1)(2 \cdot 215+1)}{6}$$

## Section 216: reading the session file

The run directory for session 216 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 217 has **bold text**, *emphasis*, `inline_code_217()` and a [link to item 217](https://example.com/items/217). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1519 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 218.1: check `step_1` and record the result in **run 218**
- Item 218.2: check `step_2` and record the result in **run 218**
- Item 218.3: check `step_3` and record the result in **run 218**
- Item 218.4: check `step_4` and record the result in **run 218**
- Item 218.5: check `step_5` and record the result in **run 218**

```dart
/// Block 219.
Future<int> handle219(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 219;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 220.1 | `os-1` | 2201 | **pass** |
| 220.2 | `os-2` | 2202 | **pass** |
| 220.3 | `os-3` | 2203 | **pass** |
| 220.4 | `os-4` | 2204 | **pass** |
| 220.5 | `os-5` | 2205 | **pass** |
| 220.6 | `os-6` | 2206 | **pass** |

Math in block 221: the inline term $a_{221} + b^2 = c_{221}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{221} k^2 = \frac{221(221+1)(2 \cdot 221+1)}{6}$$

## Section 222: reading the session file

The run directory for session 222 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 223 has **bold text**, *emphasis*, `inline_code_223()` and a [link to item 223](https://example.com/items/223). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1561 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 224.1: check `step_1` and record the result in **run 224**
- Item 224.2: check `step_2` and record the result in **run 224**
- Item 224.3: check `step_3` and record the result in **run 224**
- Item 224.4: check `step_4` and record the result in **run 224**
- Item 224.5: check `step_5` and record the result in **run 224**

```dart
/// Block 225.
Future<int> handle225(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 225;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 226.1 | `os-1` | 2261 | **pass** |
| 226.2 | `os-2` | 2262 | **pass** |
| 226.3 | `os-3` | 2263 | **pass** |
| 226.4 | `os-4` | 2264 | **pass** |
| 226.5 | `os-5` | 2265 | **pass** |
| 226.6 | `os-6` | 2266 | **pass** |

Math in block 227: the inline term $a_{227} + b^2 = c_{227}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{227} k^2 = \frac{227(227+1)(2 \cdot 227+1)}{6}$$

## Section 228: reading the session file

The run directory for session 228 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 229 has **bold text**, *emphasis*, `inline_code_229()` and a [link to item 229](https://example.com/items/229). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1603 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 230.1: check `step_1` and record the result in **run 230**
- Item 230.2: check `step_2` and record the result in **run 230**
- Item 230.3: check `step_3` and record the result in **run 230**
- Item 230.4: check `step_4` and record the result in **run 230**
- Item 230.5: check `step_5` and record the result in **run 230**

```dart
/// Block 231.
Future<int> handle231(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 231;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 232.1 | `os-1` | 2321 | **pass** |
| 232.2 | `os-2` | 2322 | **pass** |
| 232.3 | `os-3` | 2323 | **pass** |
| 232.4 | `os-4` | 2324 | **pass** |
| 232.5 | `os-5` | 2325 | **pass** |
| 232.6 | `os-6` | 2326 | **pass** |

Math in block 233: the inline term $a_{233} + b^2 = c_{233}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{233} k^2 = \frac{233(233+1)(2 \cdot 233+1)}{6}$$

## Section 234: reading the session file

The run directory for session 234 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 235 has **bold text**, *emphasis*, `inline_code_235()` and a [link to item 235](https://example.com/items/235). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1645 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 236.1: check `step_1` and record the result in **run 236**
- Item 236.2: check `step_2` and record the result in **run 236**
- Item 236.3: check `step_3` and record the result in **run 236**
- Item 236.4: check `step_4` and record the result in **run 236**
- Item 236.5: check `step_5` and record the result in **run 236**

```dart
/// Block 237.
Future<int> handle237(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 237;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 238.1 | `os-1` | 2381 | **pass** |
| 238.2 | `os-2` | 2382 | **pass** |
| 238.3 | `os-3` | 2383 | **pass** |
| 238.4 | `os-4` | 2384 | **pass** |
| 238.5 | `os-5` | 2385 | **pass** |
| 238.6 | `os-6` | 2386 | **pass** |

Math in block 239: the inline term $a_{239} + b^2 = c_{239}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{239} k^2 = \frac{239(239+1)(2 \cdot 239+1)}{6}$$

## Section 240: reading the session file

The run directory for session 240 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 241 has **bold text**, *emphasis*, `inline_code_241()` and a [link to item 241](https://example.com/items/241). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1687 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 242.1: check `step_1` and record the result in **run 242**
- Item 242.2: check `step_2` and record the result in **run 242**
- Item 242.3: check `step_3` and record the result in **run 242**
- Item 242.4: check `step_4` and record the result in **run 242**
- Item 242.5: check `step_5` and record the result in **run 242**

```dart
/// Block 243.
Future<int> handle243(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 243;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 244.1 | `os-1` | 2441 | **pass** |
| 244.2 | `os-2` | 2442 | **pass** |
| 244.3 | `os-3` | 2443 | **pass** |
| 244.4 | `os-4` | 2444 | **pass** |
| 244.5 | `os-5` | 2445 | **pass** |
| 244.6 | `os-6` | 2446 | **pass** |

Math in block 245: the inline term $a_{245} + b^2 = c_{245}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{245} k^2 = \frac{245(245+1)(2 \cdot 245+1)}{6}$$

## Section 246: reading the session file

The run directory for session 246 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 247 has **bold text**, *emphasis*, `inline_code_247()` and a [link to item 247](https://example.com/items/247). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1729 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 248.1: check `step_1` and record the result in **run 248**
- Item 248.2: check `step_2` and record the result in **run 248**
- Item 248.3: check `step_3` and record the result in **run 248**
- Item 248.4: check `step_4` and record the result in **run 248**
- Item 248.5: check `step_5` and record the result in **run 248**

```dart
/// Block 249.
Future<int> handle249(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 249;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 250.1 | `os-1` | 2501 | **pass** |
| 250.2 | `os-2` | 2502 | **pass** |
| 250.3 | `os-3` | 2503 | **pass** |
| 250.4 | `os-4` | 2504 | **pass** |
| 250.5 | `os-5` | 2505 | **pass** |
| 250.6 | `os-6` | 2506 | **pass** |

Math in block 251: the inline term $a_{251} + b^2 = c_{251}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{251} k^2 = \frac{251(251+1)(2 \cdot 251+1)}{6}$$

## Section 252: reading the session file

The run directory for session 252 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 253 has **bold text**, *emphasis*, `inline_code_253()` and a [link to item 253](https://example.com/items/253). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1771 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 254.1: check `step_1` and record the result in **run 254**
- Item 254.2: check `step_2` and record the result in **run 254**
- Item 254.3: check `step_3` and record the result in **run 254**
- Item 254.4: check `step_4` and record the result in **run 254**
- Item 254.5: check `step_5` and record the result in **run 254**

```dart
/// Block 255.
Future<int> handle255(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 255;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 256.1 | `os-1` | 2561 | **pass** |
| 256.2 | `os-2` | 2562 | **pass** |
| 256.3 | `os-3` | 2563 | **pass** |
| 256.4 | `os-4` | 2564 | **pass** |
| 256.5 | `os-5` | 2565 | **pass** |
| 256.6 | `os-6` | 2566 | **pass** |

Math in block 257: the inline term $a_{257} + b^2 = c_{257}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{257} k^2 = \frac{257(257+1)(2 \cdot 257+1)}{6}$$

## Section 258: reading the session file

The run directory for session 258 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 259 has **bold text**, *emphasis*, `inline_code_259()` and a [link to item 259](https://example.com/items/259). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1813 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 260.1: check `step_1` and record the result in **run 260**
- Item 260.2: check `step_2` and record the result in **run 260**
- Item 260.3: check `step_3` and record the result in **run 260**
- Item 260.4: check `step_4` and record the result in **run 260**
- Item 260.5: check `step_5` and record the result in **run 260**

```dart
/// Block 261.
Future<int> handle261(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 261;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 262.1 | `os-1` | 2621 | **pass** |
| 262.2 | `os-2` | 2622 | **pass** |
| 262.3 | `os-3` | 2623 | **pass** |
| 262.4 | `os-4` | 2624 | **pass** |
| 262.5 | `os-5` | 2625 | **pass** |
| 262.6 | `os-6` | 2626 | **pass** |

Math in block 263: the inline term $a_{263} + b^2 = c_{263}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{263} k^2 = \frac{263(263+1)(2 \cdot 263+1)}{6}$$

## Section 264: reading the session file

The run directory for session 264 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 265 has **bold text**, *emphasis*, `inline_code_265()` and a [link to item 265](https://example.com/items/265). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1855 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 266.1: check `step_1` and record the result in **run 266**
- Item 266.2: check `step_2` and record the result in **run 266**
- Item 266.3: check `step_3` and record the result in **run 266**
- Item 266.4: check `step_4` and record the result in **run 266**
- Item 266.5: check `step_5` and record the result in **run 266**

```dart
/// Block 267.
Future<int> handle267(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 267;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 268.1 | `os-1` | 2681 | **pass** |
| 268.2 | `os-2` | 2682 | **pass** |
| 268.3 | `os-3` | 2683 | **pass** |
| 268.4 | `os-4` | 2684 | **pass** |
| 268.5 | `os-5` | 2685 | **pass** |
| 268.6 | `os-6` | 2686 | **pass** |

Math in block 269: the inline term $a_{269} + b^2 = c_{269}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{269} k^2 = \frac{269(269+1)(2 \cdot 269+1)}{6}$$

## Section 270: reading the session file

The run directory for session 270 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 271 has **bold text**, *emphasis*, `inline_code_271()` and a [link to item 271](https://example.com/items/271). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1897 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 272.1: check `step_1` and record the result in **run 272**
- Item 272.2: check `step_2` and record the result in **run 272**
- Item 272.3: check `step_3` and record the result in **run 272**
- Item 272.4: check `step_4` and record the result in **run 272**
- Item 272.5: check `step_5` and record the result in **run 272**

```dart
/// Block 273.
Future<int> handle273(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 273;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 274.1 | `os-1` | 2741 | **pass** |
| 274.2 | `os-2` | 2742 | **pass** |
| 274.3 | `os-3` | 2743 | **pass** |
| 274.4 | `os-4` | 2744 | **pass** |
| 274.5 | `os-5` | 2745 | **pass** |
| 274.6 | `os-6` | 2746 | **pass** |

Math in block 275: the inline term $a_{275} + b^2 = c_{275}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{275} k^2 = \frac{275(275+1)(2 \cdot 275+1)}{6}$$

## Section 276: reading the session file

The run directory for session 276 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 277 has **bold text**, *emphasis*, `inline_code_277()` and a [link to item 277](https://example.com/items/277). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1939 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 278.1: check `step_1` and record the result in **run 278**
- Item 278.2: check `step_2` and record the result in **run 278**
- Item 278.3: check `step_3` and record the result in **run 278**
- Item 278.4: check `step_4` and record the result in **run 278**
- Item 278.5: check `step_5` and record the result in **run 278**

```dart
/// Block 279.
Future<int> handle279(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 279;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 280.1 | `os-1` | 2801 | **pass** |
| 280.2 | `os-2` | 2802 | **pass** |
| 280.3 | `os-3` | 2803 | **pass** |
| 280.4 | `os-4` | 2804 | **pass** |
| 280.5 | `os-5` | 2805 | **pass** |
| 280.6 | `os-6` | 2806 | **pass** |

Math in block 281: the inline term $a_{281} + b^2 = c_{281}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{281} k^2 = \frac{281(281+1)(2 \cdot 281+1)}{6}$$

## Section 282: reading the session file

The run directory for session 282 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 283 has **bold text**, *emphasis*, `inline_code_283()` and a [link to item 283](https://example.com/items/283). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 1981 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 284.1: check `step_1` and record the result in **run 284**
- Item 284.2: check `step_2` and record the result in **run 284**
- Item 284.3: check `step_3` and record the result in **run 284**
- Item 284.4: check `step_4` and record the result in **run 284**
- Item 284.5: check `step_5` and record the result in **run 284**

```dart
/// Block 285.
Future<int> handle285(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 285;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 286.1 | `os-1` | 2861 | **pass** |
| 286.2 | `os-2` | 2862 | **pass** |
| 286.3 | `os-3` | 2863 | **pass** |
| 286.4 | `os-4` | 2864 | **pass** |
| 286.5 | `os-5` | 2865 | **pass** |
| 286.6 | `os-6` | 2866 | **pass** |

Math in block 287: the inline term $a_{287} + b^2 = c_{287}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{287} k^2 = \frac{287(287+1)(2 \cdot 287+1)}{6}$$

## Section 288: reading the session file

The run directory for session 288 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 289 has **bold text**, *emphasis*, `inline_code_289()` and a [link to item 289](https://example.com/items/289). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2023 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 290.1: check `step_1` and record the result in **run 290**
- Item 290.2: check `step_2` and record the result in **run 290**
- Item 290.3: check `step_3` and record the result in **run 290**
- Item 290.4: check `step_4` and record the result in **run 290**
- Item 290.5: check `step_5` and record the result in **run 290**

```dart
/// Block 291.
Future<int> handle291(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 291;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 292.1 | `os-1` | 2921 | **pass** |
| 292.2 | `os-2` | 2922 | **pass** |
| 292.3 | `os-3` | 2923 | **pass** |
| 292.4 | `os-4` | 2924 | **pass** |
| 292.5 | `os-5` | 2925 | **pass** |
| 292.6 | `os-6` | 2926 | **pass** |

Math in block 293: the inline term $a_{293} + b^2 = c_{293}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{293} k^2 = \frac{293(293+1)(2 \cdot 293+1)}{6}$$

## Section 294: reading the session file

The run directory for session 294 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 295 has **bold text**, *emphasis*, `inline_code_295()` and a [link to item 295](https://example.com/items/295). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2065 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 296.1: check `step_1` and record the result in **run 296**
- Item 296.2: check `step_2` and record the result in **run 296**
- Item 296.3: check `step_3` and record the result in **run 296**
- Item 296.4: check `step_4` and record the result in **run 296**
- Item 296.5: check `step_5` and record the result in **run 296**

```dart
/// Block 297.
Future<int> handle297(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 297;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 298.1 | `os-1` | 2981 | **pass** |
| 298.2 | `os-2` | 2982 | **pass** |
| 298.3 | `os-3` | 2983 | **pass** |
| 298.4 | `os-4` | 2984 | **pass** |
| 298.5 | `os-5` | 2985 | **pass** |
| 298.6 | `os-6` | 2986 | **pass** |

Math in block 299: the inline term $a_{299} + b^2 = c_{299}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{299} k^2 = \frac{299(299+1)(2 \cdot 299+1)}{6}$$

## Section 300: reading the session file

The run directory for session 300 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 301 has **bold text**, *emphasis*, `inline_code_301()` and a [link to item 301](https://example.com/items/301). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2107 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 302.1: check `step_1` and record the result in **run 302**
- Item 302.2: check `step_2` and record the result in **run 302**
- Item 302.3: check `step_3` and record the result in **run 302**
- Item 302.4: check `step_4` and record the result in **run 302**
- Item 302.5: check `step_5` and record the result in **run 302**

```dart
/// Block 303.
Future<int> handle303(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 303;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 304.1 | `os-1` | 3041 | **pass** |
| 304.2 | `os-2` | 3042 | **pass** |
| 304.3 | `os-3` | 3043 | **pass** |
| 304.4 | `os-4` | 3044 | **pass** |
| 304.5 | `os-5` | 3045 | **pass** |
| 304.6 | `os-6` | 3046 | **pass** |

Math in block 305: the inline term $a_{305} + b^2 = c_{305}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{305} k^2 = \frac{305(305+1)(2 \cdot 305+1)}{6}$$

## Section 306: reading the session file

The run directory for session 306 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 307 has **bold text**, *emphasis*, `inline_code_307()` and a [link to item 307](https://example.com/items/307). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2149 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 308.1: check `step_1` and record the result in **run 308**
- Item 308.2: check `step_2` and record the result in **run 308**
- Item 308.3: check `step_3` and record the result in **run 308**
- Item 308.4: check `step_4` and record the result in **run 308**
- Item 308.5: check `step_5` and record the result in **run 308**

```dart
/// Block 309.
Future<int> handle309(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 309;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 310.1 | `os-1` | 3101 | **pass** |
| 310.2 | `os-2` | 3102 | **pass** |
| 310.3 | `os-3` | 3103 | **pass** |
| 310.4 | `os-4` | 3104 | **pass** |
| 310.5 | `os-5` | 3105 | **pass** |
| 310.6 | `os-6` | 3106 | **pass** |

Math in block 311: the inline term $a_{311} + b^2 = c_{311}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{311} k^2 = \frac{311(311+1)(2 \cdot 311+1)}{6}$$

## Section 312: reading the session file

The run directory for session 312 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 313 has **bold text**, *emphasis*, `inline_code_313()` and a [link to item 313](https://example.com/items/313). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2191 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 314.1: check `step_1` and record the result in **run 314**
- Item 314.2: check `step_2` and record the result in **run 314**
- Item 314.3: check `step_3` and record the result in **run 314**
- Item 314.4: check `step_4` and record the result in **run 314**
- Item 314.5: check `step_5` and record the result in **run 314**

```dart
/// Block 315.
Future<int> handle315(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 315;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 316.1 | `os-1` | 3161 | **pass** |
| 316.2 | `os-2` | 3162 | **pass** |
| 316.3 | `os-3` | 3163 | **pass** |
| 316.4 | `os-4` | 3164 | **pass** |
| 316.5 | `os-5` | 3165 | **pass** |
| 316.6 | `os-6` | 3166 | **pass** |

Math in block 317: the inline term $a_{317} + b^2 = c_{317}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{317} k^2 = \frac{317(317+1)(2 \cdot 317+1)}{6}$$

## Section 318: reading the session file

The run directory for session 318 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 319 has **bold text**, *emphasis*, `inline_code_319()` and a [link to item 319](https://example.com/items/319). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2233 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 320.1: check `step_1` and record the result in **run 320**
- Item 320.2: check `step_2` and record the result in **run 320**
- Item 320.3: check `step_3` and record the result in **run 320**
- Item 320.4: check `step_4` and record the result in **run 320**
- Item 320.5: check `step_5` and record the result in **run 320**

```dart
/// Block 321.
Future<int> handle321(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 321;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 322.1 | `os-1` | 3221 | **pass** |
| 322.2 | `os-2` | 3222 | **pass** |
| 322.3 | `os-3` | 3223 | **pass** |
| 322.4 | `os-4` | 3224 | **pass** |
| 322.5 | `os-5` | 3225 | **pass** |
| 322.6 | `os-6` | 3226 | **pass** |

Math in block 323: the inline term $a_{323} + b^2 = c_{323}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{323} k^2 = \frac{323(323+1)(2 \cdot 323+1)}{6}$$

## Section 324: reading the session file

The run directory for session 324 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 325 has **bold text**, *emphasis*, `inline_code_325()` and a [link to item 325](https://example.com/items/325). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2275 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 326.1: check `step_1` and record the result in **run 326**
- Item 326.2: check `step_2` and record the result in **run 326**
- Item 326.3: check `step_3` and record the result in **run 326**
- Item 326.4: check `step_4` and record the result in **run 326**
- Item 326.5: check `step_5` and record the result in **run 326**

```dart
/// Block 327.
Future<int> handle327(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 327;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 328.1 | `os-1` | 3281 | **pass** |
| 328.2 | `os-2` | 3282 | **pass** |
| 328.3 | `os-3` | 3283 | **pass** |
| 328.4 | `os-4` | 3284 | **pass** |
| 328.5 | `os-5` | 3285 | **pass** |
| 328.6 | `os-6` | 3286 | **pass** |

Math in block 329: the inline term $a_{329} + b^2 = c_{329}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{329} k^2 = \frac{329(329+1)(2 \cdot 329+1)}{6}$$

## Section 330: reading the session file

The run directory for session 330 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 331 has **bold text**, *emphasis*, `inline_code_331()` and a [link to item 331](https://example.com/items/331). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2317 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 332.1: check `step_1` and record the result in **run 332**
- Item 332.2: check `step_2` and record the result in **run 332**
- Item 332.3: check `step_3` and record the result in **run 332**
- Item 332.4: check `step_4` and record the result in **run 332**
- Item 332.5: check `step_5` and record the result in **run 332**

```dart
/// Block 333.
Future<int> handle333(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 333;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 334.1 | `os-1` | 3341 | **pass** |
| 334.2 | `os-2` | 3342 | **pass** |
| 334.3 | `os-3` | 3343 | **pass** |
| 334.4 | `os-4` | 3344 | **pass** |
| 334.5 | `os-5` | 3345 | **pass** |
| 334.6 | `os-6` | 3346 | **pass** |

Math in block 335: the inline term $a_{335} + b^2 = c_{335}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{335} k^2 = \frac{335(335+1)(2 \cdot 335+1)}{6}$$

## Section 336: reading the session file

The run directory for session 336 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 337 has **bold text**, *emphasis*, `inline_code_337()` and a [link to item 337](https://example.com/items/337). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2359 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 338.1: check `step_1` and record the result in **run 338**
- Item 338.2: check `step_2` and record the result in **run 338**
- Item 338.3: check `step_3` and record the result in **run 338**
- Item 338.4: check `step_4` and record the result in **run 338**
- Item 338.5: check `step_5` and record the result in **run 338**

```dart
/// Block 339.
Future<int> handle339(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 339;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 340.1 | `os-1` | 3401 | **pass** |
| 340.2 | `os-2` | 3402 | **pass** |
| 340.3 | `os-3` | 3403 | **pass** |
| 340.4 | `os-4` | 3404 | **pass** |
| 340.5 | `os-5` | 3405 | **pass** |
| 340.6 | `os-6` | 3406 | **pass** |

Math in block 341: the inline term $a_{341} + b^2 = c_{341}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{341} k^2 = \frac{341(341+1)(2 \cdot 341+1)}{6}$$

## Section 342: reading the session file

The run directory for session 342 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 343 has **bold text**, *emphasis*, `inline_code_343()` and a [link to item 343](https://example.com/items/343). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2401 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 344.1: check `step_1` and record the result in **run 344**
- Item 344.2: check `step_2` and record the result in **run 344**
- Item 344.3: check `step_3` and record the result in **run 344**
- Item 344.4: check `step_4` and record the result in **run 344**
- Item 344.5: check `step_5` and record the result in **run 344**

```dart
/// Block 345.
Future<int> handle345(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 345;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 346.1 | `os-1` | 3461 | **pass** |
| 346.2 | `os-2` | 3462 | **pass** |
| 346.3 | `os-3` | 3463 | **pass** |
| 346.4 | `os-4` | 3464 | **pass** |
| 346.5 | `os-5` | 3465 | **pass** |
| 346.6 | `os-6` | 3466 | **pass** |

Math in block 347: the inline term $a_{347} + b^2 = c_{347}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{347} k^2 = \frac{347(347+1)(2 \cdot 347+1)}{6}$$

## Section 348: reading the session file

The run directory for session 348 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 349 has **bold text**, *emphasis*, `inline_code_349()` and a [link to item 349](https://example.com/items/349). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2443 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 350.1: check `step_1` and record the result in **run 350**
- Item 350.2: check `step_2` and record the result in **run 350**
- Item 350.3: check `step_3` and record the result in **run 350**
- Item 350.4: check `step_4` and record the result in **run 350**
- Item 350.5: check `step_5` and record the result in **run 350**

```dart
/// Block 351.
Future<int> handle351(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 351;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 352.1 | `os-1` | 3521 | **pass** |
| 352.2 | `os-2` | 3522 | **pass** |
| 352.3 | `os-3` | 3523 | **pass** |
| 352.4 | `os-4` | 3524 | **pass** |
| 352.5 | `os-5` | 3525 | **pass** |
| 352.6 | `os-6` | 3526 | **pass** |

Math in block 353: the inline term $a_{353} + b^2 = c_{353}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{353} k^2 = \frac{353(353+1)(2 \cdot 353+1)}{6}$$

## Section 354: reading the session file

The run directory for session 354 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 355 has **bold text**, *emphasis*, `inline_code_355()` and a [link to item 355](https://example.com/items/355). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2485 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 356.1: check `step_1` and record the result in **run 356**
- Item 356.2: check `step_2` and record the result in **run 356**
- Item 356.3: check `step_3` and record the result in **run 356**
- Item 356.4: check `step_4` and record the result in **run 356**
- Item 356.5: check `step_5` and record the result in **run 356**

```dart
/// Block 357.
Future<int> handle357(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 357;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 358.1 | `os-1` | 3581 | **pass** |
| 358.2 | `os-2` | 3582 | **pass** |
| 358.3 | `os-3` | 3583 | **pass** |
| 358.4 | `os-4` | 3584 | **pass** |
| 358.5 | `os-5` | 3585 | **pass** |
| 358.6 | `os-6` | 3586 | **pass** |

Math in block 359: the inline term $a_{359} + b^2 = c_{359}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{359} k^2 = \frac{359(359+1)(2 \cdot 359+1)}{6}$$

## Section 360: reading the session file

The run directory for session 360 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 361 has **bold text**, *emphasis*, `inline_code_361()` and a [link to item 361](https://example.com/items/361). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2527 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 362.1: check `step_1` and record the result in **run 362**
- Item 362.2: check `step_2` and record the result in **run 362**
- Item 362.3: check `step_3` and record the result in **run 362**
- Item 362.4: check `step_4` and record the result in **run 362**
- Item 362.5: check `step_5` and record the result in **run 362**

```dart
/// Block 363.
Future<int> handle363(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 363;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 364.1 | `os-1` | 3641 | **pass** |
| 364.2 | `os-2` | 3642 | **pass** |
| 364.3 | `os-3` | 3643 | **pass** |
| 364.4 | `os-4` | 3644 | **pass** |
| 364.5 | `os-5` | 3645 | **pass** |
| 364.6 | `os-6` | 3646 | **pass** |

Math in block 365: the inline term $a_{365} + b^2 = c_{365}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{365} k^2 = \frac{365(365+1)(2 \cdot 365+1)}{6}$$

## Section 366: reading the session file

The run directory for session 366 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 367 has **bold text**, *emphasis*, `inline_code_367()` and a [link to item 367](https://example.com/items/367). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2569 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 368.1: check `step_1` and record the result in **run 368**
- Item 368.2: check `step_2` and record the result in **run 368**
- Item 368.3: check `step_3` and record the result in **run 368**
- Item 368.4: check `step_4` and record the result in **run 368**
- Item 368.5: check `step_5` and record the result in **run 368**

```dart
/// Block 369.
Future<int> handle369(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 369;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 370.1 | `os-1` | 3701 | **pass** |
| 370.2 | `os-2` | 3702 | **pass** |
| 370.3 | `os-3` | 3703 | **pass** |
| 370.4 | `os-4` | 3704 | **pass** |
| 370.5 | `os-5` | 3705 | **pass** |
| 370.6 | `os-6` | 3706 | **pass** |

Math in block 371: the inline term $a_{371} + b^2 = c_{371}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{371} k^2 = \frac{371(371+1)(2 \cdot 371+1)}{6}$$

## Section 372: reading the session file

The run directory for session 372 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 373 has **bold text**, *emphasis*, `inline_code_373()` and a [link to item 373](https://example.com/items/373). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2611 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 374.1: check `step_1` and record the result in **run 374**
- Item 374.2: check `step_2` and record the result in **run 374**
- Item 374.3: check `step_3` and record the result in **run 374**
- Item 374.4: check `step_4` and record the result in **run 374**
- Item 374.5: check `step_5` and record the result in **run 374**

```dart
/// Block 375.
Future<int> handle375(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 375;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 376.1 | `os-1` | 3761 | **pass** |
| 376.2 | `os-2` | 3762 | **pass** |
| 376.3 | `os-3` | 3763 | **pass** |
| 376.4 | `os-4` | 3764 | **pass** |
| 376.5 | `os-5` | 3765 | **pass** |
| 376.6 | `os-6` | 3766 | **pass** |

Math in block 377: the inline term $a_{377} + b^2 = c_{377}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{377} k^2 = \frac{377(377+1)(2 \cdot 377+1)}{6}$$

## Section 378: reading the session file

The run directory for session 378 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 379 has **bold text**, *emphasis*, `inline_code_379()` and a [link to item 379](https://example.com/items/379). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2653 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 380.1: check `step_1` and record the result in **run 380**
- Item 380.2: check `step_2` and record the result in **run 380**
- Item 380.3: check `step_3` and record the result in **run 380**
- Item 380.4: check `step_4` and record the result in **run 380**
- Item 380.5: check `step_5` and record the result in **run 380**

```dart
/// Block 381.
Future<int> handle381(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 381;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 382.1 | `os-1` | 3821 | **pass** |
| 382.2 | `os-2` | 3822 | **pass** |
| 382.3 | `os-3` | 3823 | **pass** |
| 382.4 | `os-4` | 3824 | **pass** |
| 382.5 | `os-5` | 3825 | **pass** |
| 382.6 | `os-6` | 3826 | **pass** |

Math in block 383: the inline term $a_{383} + b^2 = c_{383}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{383} k^2 = \frac{383(383+1)(2 \cdot 383+1)}{6}$$

## Section 384: reading the session file

The run directory for session 384 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 385 has **bold text**, *emphasis*, `inline_code_385()` and a [link to item 385](https://example.com/items/385). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2695 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 386.1: check `step_1` and record the result in **run 386**
- Item 386.2: check `step_2` and record the result in **run 386**
- Item 386.3: check `step_3` and record the result in **run 386**
- Item 386.4: check `step_4` and record the result in **run 386**
- Item 386.5: check `step_5` and record the result in **run 386**

```dart
/// Block 387.
Future<int> handle387(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 387;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 388.1 | `os-1` | 3881 | **pass** |
| 388.2 | `os-2` | 3882 | **pass** |
| 388.3 | `os-3` | 3883 | **pass** |
| 388.4 | `os-4` | 3884 | **pass** |
| 388.5 | `os-5` | 3885 | **pass** |
| 388.6 | `os-6` | 3886 | **pass** |

Math in block 389: the inline term $a_{389} + b^2 = c_{389}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{389} k^2 = \frac{389(389+1)(2 \cdot 389+1)}{6}$$

## Section 390: reading the session file

The run directory for session 390 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 391 has **bold text**, *emphasis*, `inline_code_391()` and a [link to item 391](https://example.com/items/391). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2737 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 392.1: check `step_1` and record the result in **run 392**
- Item 392.2: check `step_2` and record the result in **run 392**
- Item 392.3: check `step_3` and record the result in **run 392**
- Item 392.4: check `step_4` and record the result in **run 392**
- Item 392.5: check `step_5` and record the result in **run 392**

```dart
/// Block 393.
Future<int> handle393(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 393;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 394.1 | `os-1` | 3941 | **pass** |
| 394.2 | `os-2` | 3942 | **pass** |
| 394.3 | `os-3` | 3943 | **pass** |
| 394.4 | `os-4` | 3944 | **pass** |
| 394.5 | `os-5` | 3945 | **pass** |
| 394.6 | `os-6` | 3946 | **pass** |

Math in block 395: the inline term $a_{395} + b^2 = c_{395}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{395} k^2 = \frac{395(395+1)(2 \cdot 395+1)}{6}$$

## Section 396: reading the session file

The run directory for session 396 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 397 has **bold text**, *emphasis*, `inline_code_397()` and a [link to item 397](https://example.com/items/397). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2779 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 398.1: check `step_1` and record the result in **run 398**
- Item 398.2: check `step_2` and record the result in **run 398**
- Item 398.3: check `step_3` and record the result in **run 398**
- Item 398.4: check `step_4` and record the result in **run 398**
- Item 398.5: check `step_5` and record the result in **run 398**

```dart
/// Block 399.
Future<int> handle399(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 399;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 400.1 | `os-1` | 4001 | **pass** |
| 400.2 | `os-2` | 4002 | **pass** |
| 400.3 | `os-3` | 4003 | **pass** |
| 400.4 | `os-4` | 4004 | **pass** |
| 400.5 | `os-5` | 4005 | **pass** |
| 400.6 | `os-6` | 4006 | **pass** |

Math in block 401: the inline term $a_{401} + b^2 = c_{401}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{401} k^2 = \frac{401(401+1)(2 \cdot 401+1)}{6}$$

## Section 402: reading the session file

The run directory for session 402 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 403 has **bold text**, *emphasis*, `inline_code_403()` and a [link to item 403](https://example.com/items/403). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2821 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 404.1: check `step_1` and record the result in **run 404**
- Item 404.2: check `step_2` and record the result in **run 404**
- Item 404.3: check `step_3` and record the result in **run 404**
- Item 404.4: check `step_4` and record the result in **run 404**
- Item 404.5: check `step_5` and record the result in **run 404**

```dart
/// Block 405.
Future<int> handle405(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 405;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 406.1 | `os-1` | 4061 | **pass** |
| 406.2 | `os-2` | 4062 | **pass** |
| 406.3 | `os-3` | 4063 | **pass** |
| 406.4 | `os-4` | 4064 | **pass** |
| 406.5 | `os-5` | 4065 | **pass** |
| 406.6 | `os-6` | 4066 | **pass** |

Math in block 407: the inline term $a_{407} + b^2 = c_{407}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{407} k^2 = \frac{407(407+1)(2 \cdot 407+1)}{6}$$

## Section 408: reading the session file

The run directory for session 408 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 409 has **bold text**, *emphasis*, `inline_code_409()` and a [link to item 409](https://example.com/items/409). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2863 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 410.1: check `step_1` and record the result in **run 410**
- Item 410.2: check `step_2` and record the result in **run 410**
- Item 410.3: check `step_3` and record the result in **run 410**
- Item 410.4: check `step_4` and record the result in **run 410**
- Item 410.5: check `step_5` and record the result in **run 410**

```dart
/// Block 411.
Future<int> handle411(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 411;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 412.1 | `os-1` | 4121 | **pass** |
| 412.2 | `os-2` | 4122 | **pass** |
| 412.3 | `os-3` | 4123 | **pass** |
| 412.4 | `os-4` | 4124 | **pass** |
| 412.5 | `os-5` | 4125 | **pass** |
| 412.6 | `os-6` | 4126 | **pass** |

Math in block 413: the inline term $a_{413} + b^2 = c_{413}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{413} k^2 = \frac{413(413+1)(2 \cdot 413+1)}{6}$$

## Section 414: reading the session file

The run directory for session 414 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 415 has **bold text**, *emphasis*, `inline_code_415()` and a [link to item 415](https://example.com/items/415). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2905 keeps the lines distinct so nothing upstream mistakes the stream for a loop.

- Item 416.1: check `step_1` and record the result in **run 416**
- Item 416.2: check `step_2` and record the result in **run 416**
- Item 416.3: check `step_3` and record the result in **run 416**
- Item 416.4: check `step_4` and record the result in **run 416**
- Item 416.5: check `step_5` and record the result in **run 416**

```dart
/// Block 417.
Future<int> handle417(Stream<String> lines) async {
  var count = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    if (parts.length < 2) throw FormatException('bad line $line');
    count += int.parse(parts[1]) * 417;
  }
  return count;
}
```

| Run | Platform | Frames | Result |
|---|---|---|---|
| 418.1 | `os-1` | 4181 | **pass** |
| 418.2 | `os-2` | 4182 | **pass** |
| 418.3 | `os-3` | 4183 | **pass** |
| 418.4 | `os-4` | 4184 | **pass** |
| 418.5 | `os-5` | 4185 | **pass** |
| 418.6 | `os-6` | 4186 | **pass** |

Math in block 419: the inline term $a_{419} + b^2 = c_{419}$ sits in a sentence, and the display form follows.

$$\sum_{k=1}^{419} k^2 = \frac{419(419+1)(2 \cdot 419+1)}{6}$$

## Section 420: reading the session file

The run directory for session 420 holds `in.jsonl` and `out.jsonl`. Every device appends to the first and tails the second, so a dropped connection never loses a turn.

Paragraph 421 has **bold text**, *emphasis*, `inline_code_421()` and a [link to item 421](https://example.com/items/421). It goes on long enough to wrap across several lines on a phone, which is where layout cost shows: the renderer measures each word, breaks the lines and positions the inline spans. Number 2947 keeps the lines distinct so nothing upstream mistakes the stream for a loop.
