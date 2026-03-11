import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export class RepoFixture {
  readonly path: string;

  private constructor(repoPath: string) {
    this.path = repoPath;
  }

  static create(): RepoFixture {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-git-'));
    execFileSync('git', ['init', '-q'], { cwd: root, stdio: 'pipe' });
    return new RepoFixture(root);
  }

  cleanup(): void {
    fs.rmSync(this.path, { recursive: true, force: true });
  }

  writeFile(relPath: string, contents: string): void {
    const abs = path.join(this.path, relPath);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, contents, 'utf8');
  }

  renameFile(oldRel: string, newRel: string): void {
    const targetDir = path.dirname(path.join(this.path, newRel));
    fs.mkdirSync(targetDir, { recursive: true });
    execFileSync('git', ['mv', oldRel, newRel], { cwd: this.path, stdio: 'pipe' });
  }

  deleteFile(relPath: string): void {
    fs.rmSync(path.join(this.path, relPath), { force: true });
  }

  commit(message: string, authorName: string, authorEmail: string, authorDateIso: string): string {
    execFileSync('git', ['add', '-A'], { cwd: this.path, stdio: 'pipe' });
    execFileSync('git', ['commit', '-q', '--allow-empty', '-m', message], {
      cwd: this.path,
      stdio: 'pipe',
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: authorName,
        GIT_AUTHOR_EMAIL: authorEmail,
        GIT_AUTHOR_DATE: authorDateIso,
        GIT_COMMITTER_NAME: authorName,
        GIT_COMMITTER_EMAIL: authorEmail,
        GIT_COMMITTER_DATE: authorDateIso,
      },
    });
    return this.head();
  }

  head(): string {
    return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: this.path, stdio: 'pipe', encoding: 'utf8' }).trim();
  }
}
