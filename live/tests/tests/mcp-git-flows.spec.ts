import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { seedConfiguredGraph } from '../helpers/db-seed';
import { RepoFixture } from '../helpers/git-fixture';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { McpClient, toolText } from '../helpers/mcp';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-db-'));
  return path.join(dir, 'graph.db');
}

test('MCP exposes git-backed tools resources and prompts with strict commit semantics', async () => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath, { requirementId: 'REQ-001', userNeedId: 'UN-001' });
  const repo = RepoFixture.create();
  repo.writeFile('src/foo.c', '// REQ-001 implemented here\nint main(void) { return 0; }\n');
  repo.commit('REQ-001 initial implementation', 'Alice', 'alice@example.com', '2026-03-06T12:00:00Z');
  repo.writeFile('src/foo.c', '// REQ-001 implemented here\nint main(void) { return 1; }\n');
  repo.commit('refactor code path', 'Bob', 'bob@example.com', '2026-03-07T12:00:00Z');

  const port = await findFreePort();
  const server = await startServer({ dbPath, port, repoPath: repo.path });
  const mcp = new McpClient(server.baseUrl);

  try {
    const init = await mcp.initialize();
    expect(init.result?.capabilities?.tools).toBeTruthy();
    expect(init.result?.capabilities?.resources).toBeTruthy();
    expect(init.result?.capabilities?.prompts).toBeTruthy();

    const tools = await mcp.toolsList();
    const toolNames = (tools.tools || []).map((t: any) => t.name);
    expect(toolNames).toContain('implementation_changes_since');
    expect(toolNames).toContain('commit_history');
    expect(toolNames).toContain('code_traceability');

    const resources = await mcp.resourcesList();
    const resourceUris = (resources.resources || []).map((r: any) => r.uri);
    expect(resourceUris).toContain('report://status');
    expect(resourceUris).toContain('requirement://REQ-001');

    const prompts = await mcp.promptsList();
    const promptNames = (prompts.prompts || []).map((p: any) => p.name);
    expect(promptNames).toContain('trace_requirement');
    expect(promptNames).toContain('design_history_summary');

    const prompt = await mcp.promptsGet('trace_requirement', { id: 'REQ-001' });
    expect(prompt.messages?.[0]?.content?.text || '').toContain('requirement://REQ-001');
    expect(prompt.messages?.[0]?.content?.text || '').toContain('design-history://REQ-001');

    const implReq = await mcp.toolsCall('implementation_changes_since', {
      since: '2026-03-05T00:00:00Z',
      node_type: 'Requirement',
      limit: 20,
    });
    const implReqText = toolText(implReq);
    expect(implReqText).toContain('REQ-001');
    expect(implReqText).toContain('src/foo.c');

    const implNeed = await mcp.toolsCall('implementation_changes_since', {
      since: '2026-03-05T00:00:00Z',
      node_type: 'UserNeed',
      limit: 20,
    });
    const implNeedText = toolText(implNeed);
    expect(implNeedText).toContain('UN-001');
    expect(implNeedText).toContain('REQ-001');

    const traceability = await mcp.toolsCall('code_traceability', {
      repo: repo.path,
      limit: 10,
    });
    const traceabilityText = toolText(traceability);
    expect(traceabilityText).toContain('src/foo.c');

    const fileAnnotations = await mcp.toolsCall('file_annotations', {
      file_path: `${repo.path}/src/foo.c`,
      limit: 10,
    });
    const fileAnnotationsText = toolText(fileAnnotations);
    expect(fileAnnotationsText).toContain('REQ-001');
    expect(fileAnnotationsText).toContain('line_number');

    const commitHistory = await mcp.toolsCall('commit_history', {
      req_id: 'REQ-001',
      limit: 10,
    });
    const commitHistoryText = toolText(commitHistory);
    expect(commitHistoryText).toContain('REQ-001 initial implementation');
    expect(commitHistoryText).not.toContain('refactor code path');

    const requirementResource = await mcp.resourcesRead('requirement://REQ-001');
    const requirementText = requirementResource.contents?.[0]?.text || '';
    expect(requirementText).toContain('# Requirement REQ-001');
    expect(requirementText).toContain('src/foo.c');

    const designHistoryResource = await mcp.resourcesRead('design-history://REQ-001');
    const designHistoryText = designHistoryResource.contents?.[0]?.text || '';
    expect(designHistoryText).toContain('Source Files');
    expect(designHistoryText).toContain('src/foo.c');
  } finally {
    await server.stop();
    repo.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
