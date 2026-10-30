# On-device evaluation

The Evaluation tab measures how Apple's on-device model does at Make Something: how often a
generated recipe passes the dietary validator and is presented, why the others are withheld, and
how long generation takes. It exists to settle design questions, such as whether generated text
needs structured steps, with measurements from a real model.

## What a run does

- The corpus (`EvaluationCorpus`) has 12 synthetic requests: no restrictions, allergens, diets,
  both custom-exclusion severities, two diners, an adaptation, and several where the food on hand
  breaks a restriction so that the model has to leave it out. It holds no household data.
- Each case runs a chosen number of times, three by default. A run renders the prompt from the
  request's context alone (`RecipePrompt`), asks `OnDeviceRecipeRuntime` for a recipe, and passes
  it through `MakeSomething`, which validates it like any other generated recipe.
- A hard error from the model is recorded as a failed run and the evaluation continues. An
  unavailable model is recorded with the reason.

## The report

`EvaluationReport` records the device identifier, the system version, the runtimes in use, the
classification data version, and every run with its outcome (presented, withheld, unavailable or
failed), the review reasons, the unrecognized words, the unknown ingredients, the generated recipe
text and the duration. Its summary gives the counts, the presented rate among generated recipes,
how many runs each reason kind affected, the most frequent unrecognized words and unknown
ingredients, and the median, 95th percentile and maximum duration. The screen shows the summary and
every run, and shares the report as JSON.

## Where it is compiled

The tab and its code are compiled for Debug builds and for the Evaluation form of the Release
configuration, which adds the `EVALUATION` compilation condition. A normal Release build does not
contain them. `make archive-evaluation-unsigned` builds that form without signing.

## What it needs and what it does not show

- A device with Apple Intelligence turned on. The simulator does not run the model, so there the
  tab reports the model unavailable.
- Results describe the device, system version and data version in the report. A new OS release can
  change the model's behavior, so a run says nothing about other versions.
- There is no Private Cloud Compute runtime yet, so only the on-device model is measured.
- The corpus is small, so a rate from one run is an indication and not a benchmark.
