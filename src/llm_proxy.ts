import { APIGatewayProxyEventV2, Context } from "aws-lambda";
import OpenAI from 'openai';
import { APIError } from "openai/error";
import { Writable } from "stream";
import { LlmClient } from './llm_client';
import { OpenAiServerSettings, OpenAiSettings } from "./openai_settings";

export const transformGenerator = async function*<F, T>(iterator: AsyncIterator<F>, transform: (f: F) => T) {
  while (true) {
    const next = await iterator.next();
    if (next.done) { return; }
    yield transform(next.value);
  }
}

const chunkString = (chunkBody: string): string => {
  console.log('chunk', chunkBody);
  return `data: ${chunkBody}\n\n`;
}

const formatChunk = (chunk: OpenAI.Chat.Completions.ChatCompletionChunk): string => {
  const chunkBody = JSON.stringify(chunk);
  return chunkString(chunkBody);
}

export class LlmProxy {
  openAiServerSettings: OpenAiServerSettings;
  llmClients: Map<string, LlmClient> = new Map();

  constructor(openAiServerSettings: OpenAiServerSettings) {
    this.openAiServerSettings = openAiServerSettings;
  }

  streamingHandler = async (
    event: APIGatewayProxyEventV2,
    writable: Writable,
    _: Context
  ) => {
    console.log('request', JSON.stringify(event));

    const server = this.prefix(event.rawPath);
    let settings: OpenAiSettings | undefined;
    let proxyServer = server;

    if (server && server in this.openAiServerSettings) {
      settings = this.openAiServerSettings[server];
    } else if (this.openAiServerSettings['microvm-llama']?.reverse_proxy) {
      // Absolute UI paths like /v1/models or /props (no /microvm-llama prefix)
      settings = this.openAiServerSettings['microvm-llama'];
      proxyServer = '';
    }

    if (!settings) {
      this.addErrorResponse(400, writable);
      return;
    }

    if (settings.reverse_proxy) {
      await this.reverseProxy(event, writable, settings, proxyServer);
      return;
    }

    const body = event.body!;
    console.log('body', body);
    const params = JSON.parse(body) as OpenAI.Chat.Completions.ChatCompletionCreateParams;

    let llmClient: LlmClient;
    try {
      llmClient = this.getLlmClient(server);
    } catch (error) {
      this.addErrorResponse(400, writable);
      return;
    }

    if (params.stream) {
      let chunkStream;

      try {
        chunkStream = await llmClient.createCompletionStreaming(params);
      } catch (error) {
        this.handleApiError(error, writable);
        return;
      }

      const metadata = {
        statusCode: 200,
        headers: {
          "Content-Type": "text/event-stream",
        },
      };

      // @ts-expect-error
      writable = awslambda.HttpResponseStream.from(writable, metadata);

      const iterator = chunkStream[Symbol.asyncIterator]();
      for await (const chunk of transformGenerator(iterator, formatChunk)) {
        writable.write(chunk);
      }
      writable.write(chunkString('[DONE]'));
      writable.end();

    } else {
      const response = await llmClient.createCompletionNonStreaming(params);
      writable.write(JSON.stringify(response));
      writable.end();
    }
  };

  prefix(rawPath: string): string {
    return rawPath.split('/')[1];
  }

  getServerSettings(server: string): OpenAiSettings {
    if (!(server in this.openAiServerSettings)) {
      throw new Error(`No settings for server ${server}`);
    }
    return this.openAiServerSettings[server];
  }

  getLlmClient(server: string): LlmClient {
    if (this.llmClients.has(server)) {
      return this.llmClients.get(server)!;
    }

    const settings = this.getServerSettings(server);
    const llmClient = new LlmClient(settings);

    this.llmClients.set(server, llmClient);
    return llmClient;
  }

  /**
   * Same-origin reverse proxy for backends that need a custom auth header
   * (e.g. Lambda MicroVMs + llama.cpp Web UI).
   *
   * Strips the `/{server}` path prefix so llama-server can keep serving at `/`.
   * Example: /microvm-llama/v1/chat/completions → {url}/v1/chat/completions
   */
  async reverseProxy(
    event: APIGatewayProxyEventV2,
    writable: Writable,
    settings: OpenAiSettings,
    server: string,
  ) {
    const method = event.requestContext.http.method.toUpperCase();
    const query = event.rawQueryString ? `?${event.rawQueryString}` : '';
    const upstreamBase = settings.url.replace(/\/$/, '');
    const prefixRe = server ? new RegExp(`^/${server}(?=/|$)`) : null;
    let upstreamPath = prefixRe ? event.rawPath.replace(prefixRe, '') : event.rawPath;
    if (!upstreamPath) {
      upstreamPath = '/';
    }
    const upstreamUrl = `${upstreamBase}${upstreamPath}${query}`;

    const headers = new Headers();
    const authHeader = settings.auth_header || 'Authorization';
    if (authHeader.toLowerCase() === 'authorization') {
      headers.set('Authorization', `Bearer ${settings.token}`);
    } else {
      headers.set(authHeader, settings.token);
    }

    const forwardHeaderNames = [
      'accept',
      'accept-encoding',
      'accept-language',
      'content-type',
      'user-agent',
    ];
    for (const name of forwardHeaderNames) {
      const value = event.headers?.[name] || event.headers?.[name.toLowerCase()];
      if (value) {
        headers.set(name, value);
      }
    }
    // llama.cpp Web UI requires gzip; browsers send it, curl may not.
    if (!headers.has('accept-encoding')) {
      headers.set('accept-encoding', 'gzip');
    }

    let body: BodyInit | undefined;
    if (method !== 'GET' && method !== 'HEAD' && event.body) {
      body = event.isBase64Encoded
        ? Buffer.from(event.body, 'base64')
        : event.body;
    }

    console.log('reverse_proxy', method, upstreamUrl);

    let upstream: Response;
    try {
      upstream = await fetch(upstreamUrl, { method, headers, body });
    } catch (error) {
      console.log('reverse_proxy_error', error);
      this.addErrorResponse(502, writable);
      return;
    }

    const metadataHeaders: Record<string, string> = {};
    const contentType = upstream.headers.get('content-type');
    if (contentType) {
      metadataHeaders['Content-Type'] = contentType;
    }
    const cacheControl = upstream.headers.get('cache-control');
    if (cacheControl) {
      metadataHeaders['Cache-Control'] = cacheControl;
    }
    // Node fetch decompresses gzip bodies; do not forward Content-Encoding.

    const metadata = {
      statusCode: upstream.status,
      headers: metadataHeaders,
    };

    // @ts-expect-error
    writable = awslambda.HttpResponseStream.from(writable, metadata);

    if (upstream.body) {
      const reader = upstream.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        if (value && value.length > 0) {
          writable.write(Buffer.from(value));
        }
      }
    }

    writable.end();
  }

  handleApiError(error: unknown, writable: Writable) {
    console.log('API error', error);
    let statusCode = 500;
    if (error instanceof APIError && error.status) {
      statusCode = error.status!;
    }

    this.addErrorResponse(statusCode, writable);
  }

  addErrorResponse(statusCode: number, writable: Writable) {
    const metadata = {
      statusCode: statusCode,
    };

    // @ts-expect-error
    writable = awslambda.HttpResponseStream.from(writable, metadata);
    writable.write('Invalid request');

    writable.end();
  }
}
