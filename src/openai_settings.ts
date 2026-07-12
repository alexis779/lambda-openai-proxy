export interface OpenAiSettings {
    url: string;
    token: string;
    model: string;
    /** When true, forward raw HTTP (UI + API) instead of OpenAI SDK chat-only proxying. */
    reverse_proxy?: boolean;
    /** Upstream auth header name. Defaults to Authorization (Bearer). Use X-aws-proxy-auth for MicroVMs. */
    auth_header?: string;
}

export interface OpenAiServerSettings {
    [server: string]: OpenAiSettings;
}
