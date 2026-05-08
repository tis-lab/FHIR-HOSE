# LayoutLMv3 Form Understanding Setup

The Form Autofill module can use **LayoutLMv3** (token classification) for form field detection. You need to add the Core ML model and tokenizer assets to the app bundle.

## 1. Model and tokenizer assets

Use a FUNSD fine-tuned LayoutLMv3 model (e.g. `nnul/layoutlmv3-finetuned-funsd` or `nielsr/layoutlmv3-finetuned-funsd` on Hugging Face).

### Option A: Export Core ML yourself (Python)

1. Install: `transformers`, `torch`, `coremltools`, `pillow`.
2. Export `LayoutLMv3ForTokenClassification` to Core ML with **fixed** shapes:
   - `input_ids`: `[1, 512]` int32
   - `attention_mask`: `[1, 512]` int32
   - `bbox`: `[1, 512, 4]` int32 (normalized 0–1000, or match training)
   - `pixel_values`: `[1, 3, 224, 224]` float32 (ImageNet normalize)
   - Output: `logits` `[1, 512, 7]` (FUNSD: O, B/I-QUESTION, B/I-ANSWER, B/I-HEADER)
3. Save the package as `LayoutLMv3.mlpackage` and add it to the Xcode project (app target, Copy Bundle Resources).

### Option B: Use a pre-exported Core ML model

If you have or create a Core ML version of LayoutLMv3ForTokenClassification (FUNSD, 7 labels), add it to the project as above.

## 2. Tokenizer (vocab) in the bundle

LayoutLMv3 uses a RoBERTa-style tokenizer. The app expects a `vocab.json` in the bundle:

- **Preferred**: Add a `LayoutLMv3` folder (or group) in the app and put `vocab.json` inside it. The app looks for `Bundle.main.url(forResource: "vocab", withExtension: "json", subdirectory: "LayoutLMv3")`.
- **Fallback**: Add `vocab.json` at the bundle root. The app also tries `forResource: "vocab", withExtension: "json")`.

Get `vocab.json` from the same Hugging Face model repo (e.g. `nnul/layoutlmv3-finetuned-funsd` → “Files and versions” → `vocab.json`). Add it to the app target and **Copy Bundle Resources**.

## 3. Xcode

1. Add `LayoutLMv3.mlpackage` to the project and to the app target’s **Copy Bundle Resources**.
2. Add `vocab.json` (inside a `LayoutLMv3` group/folder if you use subdirectory) and include it in **Copy Bundle Resources**.

## 4. Label order

The app uses the **standard FUNSD order** (matches HuggingFace `id2label` for FUNSD):

- 0: O  
- 1: B-HEADER, 2: I-HEADER  
- 3: B-QUESTION, 4: I-QUESTION  
- 5: B-ANSWER, 6: I-ANSWER  

If your exported model was trained with a different label order, update `layoutlmv3LabelNames` in `KTCDemo.swift` to match the model’s `id2label`.

## 5. Input names

The app feeds the model with feature names: `input_ids`, `attention_mask`, `bbox`, `pixel_values`. If your Core ML model uses different input names, adjust the `MLDictionaryFeatureProvider` dictionary in `layoutlmv3RunAndDecode` in `KTCDemo.swift`.
