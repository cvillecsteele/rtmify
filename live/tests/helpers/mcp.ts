export type JsonRpcResponse = {
  jsonrpc: '2.0';
  id: number | string | null;
  result?: any;
  error?: { code: number; message: string };
};

export class McpClient {
  private nextId = 1;

  constructor(private readonly baseUrl: string) {}

  async initialize(): Promise<JsonRpcResponse> {
    return this.call('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'playwright-mcp-test', version: '1.0' },
    });
  }

  async toolsList(): Promise<any> {
    return (await this.call('tools/list')).result;
  }

  async toolsCall(name: string, args: Record<string, unknown> = {}): Promise<any> {
    return (await this.call('tools/call', { name, arguments: args })).result;
  }

  async resourcesList(): Promise<any> {
    return (await this.call('resources/list')).result;
  }

  async resourcesRead(uri: string): Promise<any> {
    return (await this.call('resources/read', { uri })).result;
  }

  async promptsList(): Promise<any> {
    return (await this.call('prompts/list')).result;
  }

  async promptsGet(name: string, args: Record<string, unknown> = {}): Promise<any> {
    return (await this.call('prompts/get', { name, arguments: args })).result;
  }

  async call(method: string, params?: Record<string, unknown>): Promise<JsonRpcResponse> {
    const id = this.nextId++;
    const res = await fetch(`${this.baseUrl}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id,
        method,
        ...(params ? { params } : {}),
      }),
    });
    if (!res.ok) throw new Error(`MCP HTTP ${res.status}`);
    return (await res.json()) as JsonRpcResponse;
  }
}

export function toolText(result: any): string {
  const content = Array.isArray(result?.content) ? result.content : [];
  return content
    .map((item: any) => (item?.type === 'text' ? String(item.text ?? '') : ''))
    .filter(Boolean)
    .join('\n');
}
