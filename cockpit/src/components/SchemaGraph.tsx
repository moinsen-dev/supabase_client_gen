/**
 * Schema graph island — React Flow + dagre auto-layout.
 *
 * Receives the normalized tables and derived references as serialized props
 * from the static page; everything here runs client-side only.
 */
import { useCallback, useMemo, useState } from 'react';
import {
  Background,
  Controls,
  Handle,
  MiniMap,
  Position,
  ReactFlow,
  type Edge,
  type Node,
  type NodeProps,
  type NodeTypes,
} from '@xyflow/react';
import dagre from '@dagrejs/dagre';
import '@xyflow/react/dist/style.css';

import type { DerivedRef, TableInfo } from '../lib/contract';

// ---------------------------------------------------------------------------
// Sizing — must match the rendered card so dagre's layout is accurate.
// ---------------------------------------------------------------------------

const NODE_WIDTH = 252;
const HEADER_HEIGHT = 42;
const ROW_HEIGHT = 23;
const NODE_PADDING_BOTTOM = 8;

function nodeHeight(table: TableInfo): number {
  return HEADER_HEIGHT + table.fields.length * ROW_HEIGHT + NODE_PADDING_BOTTOM;
}

// ---------------------------------------------------------------------------
// Table node
// ---------------------------------------------------------------------------

type TableNodeData = { table: TableInfo; selected: boolean };
type TableFlowNode = Node<TableNodeData, 'table'>;

function TableNode({ data }: NodeProps<TableFlowNode>) {
  const { table, selected } = data;
  const isView = table.kind === 'view';
  return (
    <div className={`tnode${selected ? ' tnode-selected' : ''}`}>
      <Handle type="target" position={Position.Left} className="tnode-handle" />
      <Handle type="source" position={Position.Right} className="tnode-handle" />
      <div className="tnode-header">
        <span className="tnode-name">{table.name}</span>
        {isView && <span className="tnode-badge">VIEW</span>}
        {table.ownership && <span className="tnode-ownership">{table.ownership}</span>}
      </div>
      <div className="tnode-fields">
        {table.fields.map((f) => (
          <div className="tnode-field" key={f.name}>
            <span className={`tnode-fname${f.isPrimaryKey ? ' pk' : ''}`}>
              {f.isPrimaryKey && <span className="pk-key">⚿</span>}
              {f.name}
              {f.nullable && <span className="nullable">?</span>}
            </span>
            <span className={`tnode-ftype${f.enumValues ? ' is-enum' : ''}`}>{f.type}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

const nodeTypes: NodeTypes = { table: TableNode };

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

function layout(tables: TableInfo[], refs: DerivedRef[]): { nodes: TableFlowNode[]; edges: Edge[] } {
  const g = new dagre.graphlib.Graph();
  g.setGraph({ rankdir: 'LR', nodesep: 48, ranksep: 110, marginx: 24, marginy: 24 });
  g.setDefaultEdgeLabel(() => ({}));

  for (const t of tables) {
    g.setNode(t.name, { width: NODE_WIDTH, height: nodeHeight(t) });
  }
  for (const r of refs) {
    g.setEdge(r.fromTable, r.toTable);
  }
  dagre.layout(g);

  const nodes: TableFlowNode[] = tables.map((t) => {
    const pos = g.node(t.name);
    return {
      id: t.name,
      type: 'table',
      position: { x: pos.x - NODE_WIDTH / 2, y: pos.y - nodeHeight(t) / 2 },
      data: { table: t, selected: false },
    };
  });

  const edges: Edge[] = refs.map((r, i) => ({
    id: `e-${i}-${r.fromTable}-${r.fromField}`,
    source: r.fromTable,
    target: r.toTable,
    label: r.fromField,
    type: 'smoothstep',
    labelStyle: { fill: 'var(--text-faint)', fontFamily: 'var(--mono)', fontSize: 10 },
    labelBgStyle: { fill: 'var(--bg-raised)', fillOpacity: 0.9 },
    labelBgPadding: [4, 2] as [number, number],
    labelBgBorderRadius: 4,
    style: { stroke: 'var(--border-strong)', strokeWidth: 1.5 },
  }));

  return { nodes, edges };
}

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

function accessClass(level: string): string {
  if (level === 'authenticated') return 'access-authenticated';
  if (level === 'own_row') return 'access-own-row';
  if (level === 'edge_function_only') return 'access-edge-only';
  if (level.startsWith('member_of_')) return 'access-member';
  return 'access-other';
}

function DetailPanel({ table, onClose }: { table: TableInfo; onClose: () => void }) {
  return (
    <aside className="detail-panel">
      <div className="detail-head">
        <div>
          <h2 className="detail-title">
            {table.name}
            {table.kind === 'view' && <span className="tnode-badge">VIEW</span>}
          </h2>
          <div className="detail-sub">
            schema <code>{table.schema}</code>
            {table.ownership && (
              <>
                {' · '}ownership <code>{table.ownership}</code>
              </>
            )}
            {table.primaryKey && (
              <>
                {' · '}pk <code>{table.primaryKey}</code>
              </>
            )}
          </div>
        </div>
        <button className="detail-close" onClick={onClose} aria-label="Close detail panel">
          ×
        </button>
      </div>

      {table.description && <p className="detail-desc">{table.description}</p>}

      <h3 className="detail-section">Fields</h3>
      <div className="detail-fields">
        {table.fields.map((f) => (
          <div className="detail-field" key={f.name}>
            <div className="detail-field-row">
              <span className={`tnode-fname${f.isPrimaryKey ? ' pk' : ''}`}>
                {f.isPrimaryKey && <span className="pk-key">⚿</span>}
                {f.name}
              </span>
              <span className={`tnode-ftype${f.enumValues ? ' is-enum' : ''}`}>
                {f.type}
                {f.nullable ? ' · nullable' : ''}
              </span>
            </div>
            {f.enumValues && (
              <div className="detail-enum">
                {f.enumValues.map((v) => (
                  <span className="enum-chip" key={v}>
                    {v}
                  </span>
                ))}
              </div>
            )}
          </div>
        ))}
      </div>

      {Object.keys(table.clientAccess).length > 0 && (
        <>
          <h3 className="detail-section">Client access</h3>
          <div className="detail-access">
            {(['select', 'insert', 'update', 'delete'] as const).map((op) => {
              const level = table.clientAccess[op];
              if (!level) return null;
              return (
                <div className="detail-access-row" key={op}>
                  <span className="detail-op">{op}</span>
                  <span className={`access-chip ${accessClass(level)}`}>{level}</span>
                </div>
              );
            })}
          </div>
        </>
      )}
    </aside>
  );
}

// ---------------------------------------------------------------------------
// Island root
// ---------------------------------------------------------------------------

export default function SchemaGraph({
  tables,
  refs,
}: {
  tables: TableInfo[];
  refs: DerivedRef[];
}) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const base = useMemo(() => layout(tables, refs), [tables, refs]);

  const nodes = useMemo(
    () =>
      base.nodes.map((n) => ({
        ...n,
        data: { ...n.data, selected: n.id === selectedId },
      })),
    [base.nodes, selectedId],
  );

  const onNodeClick = useCallback((_: unknown, node: Node) => {
    setSelectedId(node.id);
  }, []);

  const selectedTable = tables.find((t) => t.name === selectedId) ?? null;

  return (
    <div className="schema-graph-root">
      <ReactFlow
        nodes={nodes}
        edges={base.edges}
        nodeTypes={nodeTypes}
        onNodeClick={onNodeClick}
        onPaneClick={() => setSelectedId(null)}
        fitView
        fitViewOptions={{ padding: 0.15, maxZoom: 1 }}
        minZoom={0.15}
        proOptions={{ hideAttribution: true }}
        nodesDraggable
        nodesConnectable={false}
        colorMode="dark"
      >
        <Background gap={22} size={1} color="rgba(151,160,179,0.12)" />
        <Controls showInteractive={false} />
        <MiniMap
          pannable
          zoomable
          nodeColor={() => 'rgba(62,207,142,0.35)'}
          maskColor="rgba(11,13,17,0.75)"
          style={{ background: 'var(--bg-panel)' }}
        />
      </ReactFlow>
      {selectedTable && (
        <DetailPanel table={selectedTable} onClose={() => setSelectedId(null)} />
      )}
    </div>
  );
}
