import { fillNodeDetail } from '/modules/node-render.js';

const expandedRows = new Map();

export async function toggleRow(id, btn, colspan) {
  if (expandedRows.has(id)) {
    expandedRows.get(id).remove();
    expandedRows.delete(id);
    btn.classList.remove('open');
    btn.setAttribute('aria-expanded', 'false');
    return;
  }

  btn.classList.add('open');
  btn.setAttribute('aria-expanded', 'true');

  const detailTr = document.createElement('tr');
  detailTr.className = 'detail-row';
  detailTr.innerHTML = `<td colspan="${colspan}"><div class="detail-inner"><span class="text-hint">Loading…</span></div></td>`;
  btn.closest('tr')?.after(detailTr);
  expandedRows.set(id, detailTr);

  const inner = detailTr.querySelector('.detail-inner');
  if (inner) await fillNodeDetail(inner, id, { showProps: false });
}

export function toggleTreeSection(header) {
  const body = header.nextElementSibling;
  const btn = header.querySelector('.expand-btn');
  const opening = body.style.display === 'none';
  body.style.display = opening ? '' : 'none';
  btn?.classList.toggle('open', opening);
  btn?.setAttribute('aria-expanded', String(opening));
}

export async function toggleTreeNode(btn, id) {
  const header = btn.closest('.tree-node-header');
  const body = header?.nextElementSibling;
  if (!body) return;
  const opening = body.style.display === 'none';
  body.style.display = opening ? '' : 'none';
  btn.classList.toggle('open', opening);
  btn.setAttribute('aria-expanded', String(opening));
  if (opening && !body.dataset.loaded) {
    body.dataset.loaded = '1';
    body.innerHTML = '<span class="text-hint">Loading…</span>';
    await fillNodeDetail(body, id);
    body.querySelectorAll('.tree-section-body').forEach((section) => {
      section.style.display = '';
      const innerBtn = section.previousElementSibling?.querySelector('.expand-btn');
      if (innerBtn) {
        innerBtn.classList.add('open');
        innerBtn.setAttribute('aria-expanded', 'true');
      }
    });
  }
}

export function closeAllExpandedRows() {
  expandedRows.forEach((tr) => tr.remove());
  expandedRows.clear();
}
