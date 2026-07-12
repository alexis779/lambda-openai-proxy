# OpenAI compatible API proxy running on AWS Lambda

This AWS Lambda handler acts as a proxy to call a Large Language Model.


## Architecture

![OpenAI proxy](ArchitectureOpenAIProxy.drawio.svg)

The benefits of inserting a proxy between the frontend and the model inference service include

- Access control
- Throttling
- Logging
- Metrics
- Caching

The steps involved in deploying your own LLM include

1. Build a training dataset
2. Finetune a base LLM with QLora
3. Evaluate the predictions
4. Merge the QLora adapter with the base model
5. Deploy the merged model

Great options facilitate deploying the model. They provide public API endpoints for LLM inference with token-based authentication:

* huggingface.com
* replicate.com
* modal.com
* predibase.com
* **AWS Lambda MicroVMs** running [llama.cpp](https://github.com/ggerganov/llama.cpp) (see [microvm-llama/](microvm-llama/))

But you still need a dedicated backend API to hide the token from your client. It is a security requirement to distribute your Generative AI app without sharing your access token associated with your LLM provider of choice.

### Preferred option

The NodeJS handler runs on a Lambda *streaming* function. The response it sends is an *Event Stream*, a particular case of *Server Side Events*. Lambda will temporarily buffer messages before flushing them to the client. After testing, the buffering delay was not noticeable when summarizing a large PDF. The app was still reactive with live updates during the sequence generation.

### Alternatives considered

Introducing websockets or Server Side Events woud also provide instaneous feedback.

- Sending notifications to the websocket is possible when running a Lambda function through REST. This would require adding another API Gateway custom API in the stack, as well as managing websocket in the frontend.

- Sending live Server Side Events is possible on another AWS compute than Lambda, such as ECS/Fargate. However it would no longer be serverless.

## Examples


|LLM service|Description|model|
|---|---|---|
|OpenAI|Run GPT-4o model with your OpenAI token|gpt-4o|
|Mistral|Run Mistral Large model with your Mistral token|mistral-large-latest|
|Replicate|Run Mistral Open Source model with your Replicate token|mistralai/mistral-7b-instruct-v0.2|
|Predibase|Run a fine-tuned Open Source Mistral model, with QLora adapter|""|
|Ollama|Run quantized Mistral model locally.|mistral:latest|
|microvm-llama|llama.cpp on an AWS Lambda MicroVM (UI + OpenAI API via reverse proxy)|openbmb/MiniCPM5-1B-GGUF:Q4_K_M|


## Configuration

Use the lambda public url as the host in openai client library. Enable authorization before launch.

When calling the proxy, prepend the server key (`openai` | `mistral` | `replicate` | `predibase` | `ollama` | `microvm-llama`) in the path of the url. For example to call `replicate`, the host url is `https://abcdefghijklmnopqrstuvwxyz.lambda-url.us-west-2.on.aws/replicate/v1/chat/completions`.


### YAML server configuration

Update `openai_servers.yaml` with the list of OpenAI API compatible servers to support.

```
proxy:
  url: https://abcdefghijklmnopqrstuvwxyz.lambda-url.us-west-2.on.aws/replicate/v1
  token: api_key
  model: mistralai/mistral-7b-instruct-v0.2
openai:
  url: https://api.openai.com/v1
  token: sk-proj-...
  model: gpt-4o
mistral:
  url: https://api.mistral.ai/v1
  token: ...
  model: mistral-large-latest
replicate:
  url: https://openai-proxy.replicate.com/v1
  token: r8_...
  model: mistralai/mistral-7b-instruct-v0.2
predibase:
  url: https://serving.app.predibase.com/028bc858/deployments/v2/llms/mistral-7b-instruct-v0-3/v1
  token: pb_...
  model: ""
ollama:
  url: http://127.0.0.1:11434/v1
  token: ollama_token
  model: mistral:latest
microvm-llama:
  url: https://xxxxxxxx.lambda-microvm.us-west-2.on.aws
  token: "<microvm-auth-token>"
  model: openbmb/MiniCPM5-1B-GGUF:Q4_K_M
  reverse_proxy: true
  auth_header: X-aws-proxy-auth
```

### Lambda MicroVM + llama.cpp

[microvm-llama/](microvm-llama/) packages `llama-server` in an AWS Lambda MicroVM. MicroVM ingress requires the `X-aws-proxy-auth` header, which browsers cannot set for a normal page load.

This proxy acts as the **same-origin front door**:

1. Deploy and run the MicroVM (see [microvm-llama/README.md](microvm-llama/README.md)).
2. Put the MicroVM HTTPS endpoint and a token from `create-microvm-auth-token` into `openai_servers.yaml` as shown above (`reverse_proxy: true`).
3. Build and deploy this Lambda proxy (`npm run build`, copy `openai_servers.yaml` into `dist/`, then `sam deploy`).
4. Open the Function URL path `/microvm-llama/` in a browser for the llama.cpp Web UI, or call `/microvm-llama/v1/chat/completions` like any other OpenAI-compatible backend.

With `reverse_proxy: true`, the handler forwards raw HTTP (UI assets, `/props`, `/v1/*`, SSE) and injects `auth_header` instead of using the OpenAI SDK. Tokens expire after at most 60 minutes; refresh the yaml entry and redeploy when they expire.

## Clients
### curl

```
ENDPOINT=https://abcdefghijklmnopqrstuvwxyz.lambda-url.us-west-2.on.aws/replicate/v1
API_TOKEN=api_token
MODEL=meta/meta-llama-3-70b-instruct

curl "$ENDPOINT/chat/completions" \
    -d '{ "model": "$MODEL, "messages": [ { "role": "user", "content": "Tell me a joke" } ], "stream": true }' \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $API_TOKEN" \
```

### NodeJS

Here's the client code,

```JavaScript
import OpenAi from 'openai';


const server = 'replicate';
const baseURL = `https://abcdefghijklmnopqrstuvwxyz.lambda-url.us-west-2.on.aws/${server}/v1/`;
const apiKey = 'r8_...';
const openAi = new OpenAi({
    baseURL: baseURL,
    apiKey: apiKey,
});

const model = 'mistralai/mistral-7b-instruct-v0.2';
const prompt = 'Tell me a joke.'
const params = {
    model: model,
    messages: [{ role: 'user', content: prompt }],
    stream: true,
};

const chunks = await openai.chat.completions.create(params);
let response = '';
for await (const chunk of chunks) {
  response += chunk.choices[0].delta.content;
  updateAssistantResponse(response);
}

```

### Test

```
$ npm run test

 PASS  src/tests/index.test.ts (7.044 s)
  app
    Unit
      ✓ Streaming (1499 ms)
      ✓ Non Streaming (1508 ms)
      ○ skipped Above 32k context size
    Integration
      ✓ Streaming (847 ms)
      ✓ Non streaming (1342 ms)
```


### Build

Transpilation will update the `dist` folder with the `index.js` file pending deployment to Lambda code.
Include the configuration file containing the api tokens of the supported LLM servers.

```
$ npm run build
$ cp openai_servers.yaml dist/
```


### Deploy

Create the Lambda function using the provided SAM template.

Deploy the code.

```
sam deploy --guided
```
