# Feature Specification: Barnard Core SDK（BLEセンシング基盤）

**Feature Directory**: `specs/001-barnard-core-sdk`  
**Created**: 2025-12-15  
**Status**: Draft  
**Input**: BLEセンシングのためのプラグイン／SDKを、Flutter以外（RN / iOS / Android）へも配布できる“ネイティブSDKコア”として再設計する。Barnard は BLE の Scan/Advertise とイベント（メイン＋デバッグ）提供までを責務とし、VC/POAP等のドメインロジックやサーバ依存、UIは非責務とする。

## Clarifications（確定した前提）

本featureの検討において、以下を前提として確定する（2025-12-16時点）。

- Barnard は payload を **parseする責務を持つ**。加えて、RPID を生成し、ブロードキャストしつつセンシングする手続きを担う
- payload には **デバイス固有IDのような永続識別子を含めない**
- センシング結果として「現地の空間の環境データ」を各デバイス視点で記録したい  
  → 検出イベントでは **RPID（payload由来） + RSSI（受信側測定値）** を必須で扱う
- ここで言う「環境データ」は **受信側が観測した事実**（どの `rpid` を、どんな `rssi` で、いつ観測したか）のことを指し、接続先（相手端末）から追加データを受け取ることは前提にしない
- OS差分（特に iOS のプライバシー/制約）を吸収し、上位に“判断可能な情報”として返す
- プロトタイプ段階の動作保証範囲は **フォアグラウンドのみ**
- プロトタイプ段階の scan/advertise は **ほぼ設定項目なし**（安全に倒したデフォルト）で開始できる
- 同時に Scan + Advertise は **第一級機能（Autoモード）** とする
- debugEvents は push + pull を用意し、保存はメモリバッファ（上限あり）。RSSIは平均だけではなく **サンプリング** を検討する
- デバッグUI向けに、追跡リスクを増やさない形で短い `displayId`（例: RPID先頭の短縮表現）を提供してよい

### Terminology（用語統一）

誤訳を避けるため、この仕様では専門用語を以下に統一する（以後は原則この表記のみを使う）。

- **Scan**: 周辺の Advertise を検出する（Central 側の動作）
- **Advertise**: 周辺へ広告を送出する（Peripheral 側の動作）
- **Central / Peripheral**: CoreBluetooth の役割名（OSの用語に合わせる）
- **GATT**: 接続後の Service/Characteristic による通信（`read` / `notify` / `write`）
- **Transport**: Scan/Advertise 等の無線レイヤ実装（BLE/UWB/Thread 等）。Barnard は Transport を差し替え可能な形で扱う

### Decisions（2025-12-16）

- `rpid + rssi` の時系列は **受信側が観測した事実**であり、相手端末から追加データを受け取る前提は置かない
- 高密度（将来: 2000台規模）を想定し、基本線は **connectionless**（接続なし）で `rpid` を運ぶ
- iOS は connectionless を優先し、無理な場合のみ **GATT fallback**（目標: Read+Notify / 及第点: Readのみ）を使う
- 将来の BLE 以外（UWB/Thread 等）も視野に、API/実装は **Transport-agnostic** を前提にする

## User Scenarios & Testing *(mandatory)*

### User Story 1 - アプリ開発者が Scan して検出イベントを受け取れる (Priority: P1)

アプリ/上位SDKの開発者として、Barnard を開始して BLE Scan を行い、検出した結果を「使いやすいイベント」として受け取りたい。権限不足やBluetooth OFF、バックグラウンド制約などは、失敗理由として明確に通知されたい。

**Why this priority**: センシングの根幹。ここが成立しないと周辺（Beid/VC/POAP）へ進めない。

**Independent Test**: iOS/Android 実機で Scan 開始→検出→停止までを実施し、検出イベントと制約/エラーイベントが観測できること。

**Acceptance Scenarios**:
1. **Given** Bluetooth ON & 権限OK、**When** Scan 開始、**Then** 状態が `scanning` になり、検出時に `detection` イベントが発行される
2. **Given** Bluetooth OFF、**When** Scan 開始、**Then** `bluetooth_off` 相当の制約/エラーが通知され、開始できない（もしくは即停止）ことが分かる
3. **Given** 権限不足、**When** Scan 開始、**Then** `permission_denied` 相当の制約/エラーが通知される

---

### User Story 2 - アプリ開発者が Advertise（broadcast）できる (Priority: P1)

アプリ/上位SDKの開発者として、Barnard で BLE Advertise を開始/停止し、payload フォーマットとバージョンが明示された形で送出したい。制約（バックグラウンド不可など）も通知されたい。

**Why this priority**: センシング基盤として Scan と対になる必須機能。

**Independent Test**: iOS/Android 実機で Advertise 開始→停止までを実施し、状態遷移と制約/エラーが観測できること。

**Acceptance Scenarios**:
1. **Given** Bluetooth ON & 権限OK、**When** Advertise 開始、**Then** 状態が `advertising` になり、停止で `idle` に戻る
2. **Given** OS制約で Advertise 不可、**When** Advertise 開始、**Then** 理由コード付きで失敗が通知される

---

### User Story 3 - オタクモード向けに内部イベントを観測できる (Priority: P2)

開発者として、Barnard 内部で何が起きているか（タイムライン、状態遷移、エラー/警告、検出のraw/parsed）を `debugEvents` として受け取り、Beid 側で可視化・原因切り分けしたい。ただしPIIや秘密情報は含めたくない。

**Why this priority**: BLEはOS差分と制約が多く、観測性がないと運用・検証が困難。

**Independent Test**: Scan/Advertise 操作に対し、開始/停止/状態遷移/エラーがデバッグイベントとして時系列に記録されること。イベント量が過多にならないこと。

**Acceptance Scenarios**:
1. **Given** デバッグ購読ON、**When** Scan 開始/停止、**Then** `scan_start/scan_stop` と状態遷移イベントが発行される
2. **Given** 高頻度RSSIが発生、**When** デバッグ購読ON、**Then** サンプリング/集約等で上限制御された形で提供される（破綻しない）

---

### User Story 4 - 複数配布形態に耐えるコア構成ができている (Priority: P2)

開発者として、ネイティブSDKをコアとして、iOSは SPM、Androidは Maven/Gradle、将来的に Flutter（pub.dev）/React Native（npm）へ薄いラッパーで展開できる設計になっていてほしい。プロトタイプ段階では「全部の本番公開」ではなく、構成・ビルド・サンプル動作が成立していればよい。

**Why this priority**: 今後の配布先拡大のための前提条件。

**Independent Test**: iOS/Androidで“ネイティブSDKとして”組み込める（ビルドできる）こと。さらに Flutter/RN は最小の呼び出し経路（骨格）を確認できること。

**Acceptance Scenarios**:
1. **Given** iOSプロジェクト、**When** SPM で依存追加、**Then** Scan/Advertise の最小サンプルが動く
2. **Given** Androidプロジェクト、**When** Gradle/Maven で依存追加、**Then** Scan/Advertise の最小サンプルが動く

### Edge Cases

- 連続して `startScan()` が呼ばれたとき（冪等/エラー/再起動の扱いは？）
- Scan 中に権限が取り消されたとき（状態遷移と通知は？）
- Bluetooth が途中でOFFになったとき
- バックグラウンド遷移中/復帰時の挙動（OSごとの差分）
- payload の解析に失敗したとき（rawは出す？ parsedはnull？ エラーイベント？）
- デバッグイベントが大量に発生する場合の保持上限/サンプリング戦略

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Barnard は iOS/Android で BLE Scan の開始/停止を提供しなければならない
- **FR-002**: Barnard は検出イベントを、上位が扱いやすい構造化イベントとして提供しなければならない（検出時刻、RSSI、識別子、payload raw/parsed 等）
- **FR-003**: Barnard は BLE Advertise の開始/停止を提供しなければならない
- **FR-004**: Barnard は Advertise payload のフォーマットとバージョンを明示しなければならない
- **FR-005**: Barnard は権限不足、Bluetooth OFF、OS制約、バックグラウンド不可等を“理由コード付き”で通知しなければならない
- **FR-006**: Barnard は Scan/Advertise の状態を明確に定義し、状態遷移を上位へ通知できなければならない
- **FR-007**: Barnard は `debugEvents`（タイムライン、状態遷移、エラー/警告、検出raw/parsed、メトリクス）を提供できなければならない
- **FR-008**: `debugEvents` は秘密情報/PIIを含まず、頻度・保持の制御（サンプリング、集約、バッファ上限）を備えなければならない
- **FR-009**: Barnard は特定サーバURLやAPI仕様に依存してはならない（アプリ側で実装する）
- **FR-010**: Barnard は VC発行/検証、POAP発行等のドメインロジックを実装してはならない
- **FR-011**: Barnard は iOS(SPM) / Android(Maven/Gradle) の配布形態を前提に、将来 Flutter(pub.dev) / React Native(npm) を薄いラッパーで提供できる構造でなければならない
- **FR-012**: Barnard はプラットフォーム制約を抽象化しつつ、必要に応じて上位が判断できる情報を返さなければならない
- **FR-013**: Barnard は RPID（Rotating Proximity ID）を生成し、Advertise payload へ載せ、受信側でparseして検出イベントに含めなければならない
- **FR-014**: Barnard は同時に Scan + Advertise を開始/停止できる Autoモード（第一級機能）を提供しなければならない
- **FR-015**: プロトタイプ段階では、Barnard はフォアグラウンド動作のみを動作保証範囲とし、バックグラウンドは未サポートとして明示しなければならない
- **FR-016**: `debugEvents` は push（ストリーム）と pull（スナップショット/バッファ取得）を提供しなければならない
- **FR-017**: Barnard は debug用途の `displayId`（短い識別表示。例: ハッシュ先頭）を提供してよい（追跡リスクを増やさない形）
- **FR-018**: Barnard は RSSI を「平均値」だけで潰さず、時系列として扱える **サンプリング/保持** の仕組み（上限あり）を提供しなければならない
- **FR-019**: RPID の rotationSeconds は debug用途で上位から調整できなければならない（ただし安全側の上限/下限を設ける）
- **FR-020**: プロトタイプ段階の `ScanConfig` / `AdvertiseConfig` は最小限とし、未指定でも開始できるデフォルトを提供しなければならない
- **FR-021**: iOS等で Advertise だけでは `rpid` を安定して運べない/拡張できない場合に備え、Barnard は **接続（GATT）による data exchange** をサポートできなければならない（接続/再接続/最小Read/Notify/Write）

### Platform Requirements

- **FR-IOS-001**: iOS では `NSBluetoothAlwaysUsageDescription` を要求し、ホストアプリに設定が必要であることをドキュメント化しなければならない
- **FR-IOS-002**: バックグラウンドでの Scan/Advertise をサポートする場合、ホストアプリで `UIBackgroundModes` に `bluetooth-central` / `bluetooth-peripheral` が必要であることをドキュメント化しなければならない
- **FR-IOS-003**: iOS 実装は必要に応じて State Restoration を利用できる設計でなければならない（`CBCentralManagerOptionRestoreIdentifierKey` / `CBPeripheralManagerOptionRestoreIdentifierKey` の採用を含む）

### Prototype API Sketch（設定最小）

プロトタイプでは「何も設定しなくても Scan/Advertise/Auto が動く」ことを優先し、設定は **debug用途の上書き** に寄せる。

- `startScan(config?)` / `stopScan()`
- `startAdvertise(config?)` / `stopAdvertise()`
- `startAuto(config?)` / `stopAuto()`（第一級）
- `events`（detection / state / constraint / error）
- `debugEvents`（push）+ `getDebugBuffer()`（pull）
- `getRssiSamples({ since?, limit?, rpid? })`（pull。時系列を返す）

`config` の例（概念。言語別に適用）:

- `rpid.rotationSeconds`（default: 600, 範囲: 60..3600）
- `rssi.minPushIntervalMs`（default: 1000）
- `rssi.bufferMaxSamples`（default: 20000）

## RPID（Rotating Proximity ID）と Payload 仕様（ドラフト）

Barnard は「デバイス固有IDを Advertise に含めない」一方で、近接センシングに必要な相関キーとして RPID を扱う。

- **RPID の目的**: 受信側が「同一時間窓における同一送信者の Advertise」を相関できること（追跡可能性は最小化）
- **回転（rotation）**: 既定は **10分**（暫定）。debug用途で上位から変更可能とする（ただし安全側の上限/下限を設ける）
- **非目標**: RPID からデバイス固有性が推測できないこと（永続IDに結び付かない）

### 推奨生成（実装案・要調整）

- 各端末はローカルに `rpidSeed`（ランダムな秘密）を保持する（外部送信しない）
- 現在時刻から `windowIndex = floor(unixTimeSeconds / rotationSeconds)` を計算する
- `rpid = Truncate(HMAC-SHA256(rpidSeed, windowIndex), 16 bytes)` のような決定的生成を行う  
  ※ 目的は“同一窓での安定性”と“窓を跨いだ追跡耐性”。詳細は plan で確定する

### 追跡リスク最小化（Barnardとしての方針）

- RPID は **端末内の秘密（`rpidSeed`）から擬似乱数的に生成**し、外部へ送信しない（seed露出がない限り他者が予測できない）
- `rpidSeed` は「再インストールで消える」ストレージに置く（iOS Keychain のようにアンインストール後も残り得る領域は避ける方針）
- rotationSeconds を短くしすぎると観測粒度は上がるが、バッテリー/処理負荷が上がるため、**安全側の範囲**（例: 60s〜3600s）を設ける
- 端末ごとに `epochOffsetSeconds`（0〜rotationSeconds未満のランダム）を持たせ、回転境界が同時刻に揃いにくいようにしてよい（受信側は payload を読むだけなので同期不要）

### displayId（デバッグ表示用）

- `displayId` は UI表示の利便性のための短縮表現であり、**RPIDから一方向に導出**する（例: `hex(rpid[0..4])` / base32先頭など）
- `displayId` は RPID と同じ回転で変わるため、永続識別子にならない

### Advertise Payload（最小）

Barnard が扱う「payload」は **論理フォーマット（抽象）** とし、OSが許す範囲で on-wire へのエンコードは変わり得る（ただし Barnard が吸収して `rpid` を正規化して返す）。

- `formatVersion`: 1（プロトタイプは固定。上位へは明示的に返す）
- `rpid`: 16 bytes（検出イベントのキー）
- （将来拡張）`payloadType` / `flags` / `reserved` 等

#### iOS on-wire（CoreBluetooth Peripheral）

iOS の Peripheral Advertise は Advertise データに載せられるキーが限定されるため、Barnard は iOS においても **可能な限り connectionless**（接続しない）で `rpid` を運ぶ設計を基本線とする。

- Advertise（discovery）: 固定の Service UUID（= Barnard Discovery Service）+ 固定の短い Local Name（例: `BNRD`）
- Advertise（rpid）: OSが許す範囲で `rpid` を Advertise に載せる（例: Service UUID / Service Data 等）。受信側は Advertise を parse して `rpid` を取得する

この場合、受信側は「Scan で検出 → Advertise を parse して `rpid` を取得」したうえで、検出イベントに `rpid + rssi` を必ず含める。
`rssi` は（1）Scan時のRSSI（scan callback）か（2）接続後のRSSI（readRSSI等）で取得できるが、空間環境データ用途では時系列になるため Barnard 側のサンプリング/保持が重要になる。

#### iOS: GATT（optional / fallback）

connectionless で `rpid` を運べない/不安定な場合に備え、Barnard は **GATT fallback** を持てる設計にする。

- Central が接続した後、GATT で `rpid` を取得する
- `rpid` 取得は **Read + Notify の両対応**を目標とし、及第点は **Read のみ**とする

#### Android on-wire（暫定）

Android は一般に iOS より Advertise データの自由度が高い。プロトタイプでは「iOSで成立する最小」を優先し、拡張（Service Data / Manufacturer Data 等）は後続で扱う。

受信側は payload を parseし、検出イベントとして **`rpid` と `rssi`（測定値）** を必須で提供する。

### Payload バージョニング（暫定）

- `formatVersion` を **破壊的変更の境界**とする（`1` の間は後方互換の拡張のみ）
- `formatVersion` が未知の値の場合は `payloadParsed = null` とし、`payloadRaw` と「unsupported_version」系の debug/constraint を返せるようにする

## RSSI サンプリングとメモリバッファ（ドラフト）

RSSI は「空間環境データ」のシグナルとして情報量があり、単純平均だけでは表現力が弱い。Barnard は push/pull 両方で扱えるようにする。

### push（ストリーム）: 破綻しないイベント設計

- `detection` は高頻度になり得るため、push側では **サンプリング/間引き** を行ってよい
- 例: 同一 `rpid` に対しては `minPushIntervalMs`（例: 500〜2000ms）を設け、その間に得たRSSIを `count/min/max/mean` 等にまとめた `rssiSummary` として送る

### pull（バッファ取得）: 時系列を返す

- 内部にリングバッファ（メモリのみ）を持ち、`RssiSample { timestamp, rpid, rssi }` を保存する
- 上限は「サンプル数」もしくは「メモリ見積り」ベースで固定（例: 20,000 samples）。超過時は古いものから破棄する
- pull API では `since`（時刻）/ `limit` を指定して取得できる想定（必要なら `rpid` でフィルタ）

### デフォルト（プロトタイプ）

- pushは「破綻しない」こと優先で間引きあり、pullは可能な限り生データを保持する（ただし上限あり）

## Autoモード（Scan + Advertise 同時）

プロトタイプでは Scan と Advertise を別々に扱うよりも、「同時に動かす」ことを第一級のユースケースとする。

- `startAuto()` は **scan+advertise を同時に開始**し、`stopAuto()` は両方を停止する
- 片方だけ失敗し得るため、開始結果は「成功/失敗」だけでなく **部分成功** を表現できるようにする（例: `started: { scanning: true, advertising: false }` + 理由コード）
- 状態モデルは「単一state文字列」よりも `isScanning/isAdvertising` のように **直交で表現**できると実装差分を吸収しやすい（上位には簡易stateも返せる）

## iOS制約と GATT（connectionless 優先）

iOS はプライバシー/省電力の観点で BLE の扱いに制約があり、Advertise に載せられる情報量やフォーマットが制限される。Barnard は **connectionless を基本線**にしつつ、必要なら GATT fallback を使えるようにする。

### iOS: Advertise/Scan の前提（フォアグラウンド）

- プロトタイプはフォアグラウンドのみ。バックグラウンド要件（`UIBackgroundModes` 等）は **将来** として切り出す
- iOS Peripheral の Advertise データは制約が強い（載せられるキーが限定される）。プロトタイプは **固定 Service UUID + 固定 Local Name** を discovery の軸にし、`rpid` は可能なら Advertise に載せて parse する（無理なら GATT fallback）
- RSSI 時系列のため、Scan 側は `AllowDuplicates` を `true` にする必要が出る可能性がある（その場合は Barnard 側のサンプリングで破綻を防ぐ）

### GATT（optional / fallback）

Advertise に `rpid` を載せられない/安定しない場合に備え、GATT を fallback として使う。高密度（例: 2000台）環境では接続がボトルネックになるため、GATT は **デフォルトOFF**（上位opt-in）または **厳密な接続予算**の下でのみ使う。

- Advertise は discovery 用途に寄せる（固定 Service UUID）
- Central は Scan で検出した Peripheral へ接続し、GATT で `rpid` を受け取る
- `rpid` 取得は **Read + Notify の両対応**を目標とし、及第点は **Read のみ**とする
- 接続制御（例）: `maxConcurrentConnections=1` / `cooldownPerPeripheral` / `connectBudgetPerMinute` / `maxConnectQueue`

## Architecture Sketch（Transport-agnostic / Clean Architecture）

Barnard は将来 BLE 以外（UWB / Thread 等）も視野に入れ、Scan/Advertise を **Transport に抽象化**する。上位は「Transportが何か」を意識せずに、同一のイベント/データモデルで扱えることを目標とする。

- `BarnardCore`（純粋ロジック）: RPID 生成、payload parse、RSSI buffer、サンプリング、状態遷移、debug buffer
- `Transport`（差し替え可能）: Scan/Advertise の開始停止、検出イベント（raw）を Core へ渡す
- `PlatformDriver`（OS実装）: iOS CoreBluetooth / Android BLE API / 将来の UWB/Thread 実装

Core が受け取る最小入力（概念）:

- `TransportDetection { timestamp, transportKind, rawPayload?, rssi, metadata }`

Core が上位へ出す最小出力:

- `DetectionEvent { timestamp, rpid, rssi, transportKind, displayId?, payloadVersion }`

Transport の capabilities（例）:

- `supportsConnectionlessRpid`（Advertise に `rpid` を載せられる）
- `supportsGattFallback`（接続で `rpid` を取れる）
- `supportsRssiHighRate`（高頻度RSSI取得の可否/制限）

## Reference Implementation Notes（既存サンプルからの学び）

過去に作成した iOS の参考実装で確認できた “まず動かす” ための要点を、プロトタイプの初期前提として取り込む（この仕様だけで実装判断できるように記述する）。

- Scan は固定の discovery service を `withServices: [...]` でフィルタし、検出後は接続して `discoverServices/Characteristics` し、必要なら Notify を購読する（`AllowDuplicates` はRSSI時系列要件に応じて検討）
- Advertise は `CBAdvertisementDataLocalNameKey` と `CBAdvertisementDataServiceUUIDsKey`（サービスUUID）で最小構成になっている
- Central / Peripheral の state 変化（`poweredOn/off/unauthorized/unsupported` 等）をログとして観測している
- バックグラウンド要件: `UIBackgroundModes` に `bluetooth-central` / `bluetooth-peripheral`、かつ `NSBluetoothAlwaysUsageDescription` が必要
- “Autoモード”として Scan と Advertise を同時に開始できる（運用/デバッグに有用）
- GATT の最小構成（128-bit Service + Write/Notify characteristic）で相互接続・Notify送受信の例がある  
  ※ `rpid` を GATT で運ぶ場合は Read/Notify を使い分けられるようにする（目標: 両対応、及第点: Readのみ）

### Key Entities *(include if feature involves data)*

- **BarnardState**: `idle / scanning / advertising / error` 等の状態（最小セット）
- **StateTransition**: `from/to` と理由（ユーザー操作/OS制約/エラー等）
- **ScanConfig**: フィルタ/間隔/対象payload種別等（プロトタイプは最小限）
- **AdvertiseConfig**: payload、送出モード等（プロトタイプは最小限）
- **DetectionEvent**: `timestamp`, `rssi`, `identifier`, `payloadRaw`, `payloadParsed?`, `sourcePlatform`
- **ConstraintEvent / ErrorEvent**: `code`, `message?`, `recoverability`, `requiredAction?`
- **DebugEvent**: タイムラインイベント（開始/停止/検出/権限変化/Bluetooth変化/警告/エラー/メトリクス）
- **MetricsSnapshot**: 検出件数、最終検出時刻、平均RSSI、稼働時間、エラー回数 等
- **PayloadFormat**: `name`, `version`, `fields`（互換性のための宣言）
- **RPID**: Rotating Proximity ID（payload内に格納され、検出イベントのキーとなる）
- **RPIDConfig**: `rotationSeconds` 等（debug用途の上位調整を含む）
- **RssiSample**: `timestamp`, `rssi`（高頻度になり得るためサンプリング制御対象）
- **RssiSummary**: `count/min/max/mean` 等（push側の間引き・集約用）
- **RssiBuffer**: メモリリングバッファ（pull取得のための保持領域）
- **displayId**: デバッグUI向け短縮ID（RPIDから導出）

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: iOS/Android 実機で Scan 開始→検出→停止が成功し、検出イベントが取得できる
- **SC-002**: iOS/Android 実機で Advertise 開始→停止が成功し、状態遷移が取得できる
- **SC-003**: 権限不足/Bluetooth OFF/OS制約など主要な失敗パスで、理由コード付きイベントが取得できる
- **SC-004**: デバッグイベントが時系列と状態遷移を破綻なく提供し、PII/秘密情報を含まない
- **SC-005**: 配布戦略（SPM/Maven + Flutter/RN薄ラッパー）の方針と骨格が仕様として合意される

## Open Questions / Clarifications

- RPID の生成方式の細部（seed格納先の具体、epochOffset採否、rotationSecondsの上下限）を確定する
- RSSI サンプリング戦略の既定値（`minPushIntervalMs` / バッファ上限 / pull API の形）を確定する
- Autoモードの失敗時振る舞い（部分成功の表現、復旧/再試行ポリシー）を確定する
- iOS の connectionless `rpid` on-wire（Service UUID / Service Data など、どのフィールドを使うか）と、その parse 仕様を確定する
- 高密度（将来 2000台規模）での Scan 設定（Filter / AllowDuplicates / サンプリング既定値）を確定する
- GATT fallback の有効化条件（デフォルトOFFか、debug-onlyか）と、接続予算 knobs（`maxConcurrentConnections` / `connectBudgetPerMinute` 等）の既定値を確定する
- Transport 抽象の最小インターフェース（入力 `TransportDetection` / 出力 `DetectionEvent` / capabilities）を確定する
