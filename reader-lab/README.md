# Reader lab

Measures reading modes on real pages, with labels taken from each site's own content
selector. Models are scored only on sites they did not train on. Runs in invisible
WebKit. Captures hold page text, so they stay outside the repository.

```sh
node make-corpus.mjs <lab>/corpus.json
xcrun swiftc -O -parse-as-library -framework AppKit -framework WebKit capture.swift -o <lab>/capture
<lab>/capture <lab>/corpus.json ../reader/extract.js <Readability.js> ../adblock/rules.json.deflate <lab>/out
python3 prepare.py <lab>/out <lab>
xcrun swiftc -O -parse-as-library train.swift -o <lab>/train && <lab>/train <lab>
python3 score.py <lab>
```

Compile the trained model into the browser with `compile-model.swift`. The compiled
model holds numbers derived from block features, not page text.

Result on 86 pages from 41 sites, scored on sites unseen in training: old reader F1 0.76,
Readability 0.86, Readability guarded by the model 0.90. Failures (F1 below 0.5) fall
from 9% to 3%, and correct refusals of non-articles rise from 2 of 10 to 6 of 10. By site,
guarded minus Readability is +0.026, 95% interval +0.003 to +0.056. The guard's settings
were chosen on this same corpus, so the gain may be somewhat optimistic.
