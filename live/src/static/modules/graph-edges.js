export function humanEdgeLabel(currentType, edge, dir) {
  const otherType = edge?.node?.type || '';
  const label = edge?.label || '';

  switch (label) {
    case 'DERIVES_FROM':
      if (currentType === 'UserNeed' && dir === 'in' && otherType === 'Requirement') return 'Derived Requirement';
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'UserNeed') return 'Source User Need';
      if (currentType === 'Requirement' && dir === 'in' && otherType === 'Requirement') return 'Child Requirement';
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'Requirement') return 'Parent Requirement';
      return 'Derivation Link';
    case 'REFINED_BY':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'Requirement') return 'Refined By Requirement';
      if (currentType === 'Requirement' && dir === 'in' && otherType === 'Requirement') return 'Refines Requirement';
      return 'Refinement Link';
    case 'TESTED_BY':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'TestGroup') return 'Verifying Test Group';
      if (currentType === 'TestGroup' && dir === 'in' && otherType === 'Requirement') return 'Verified Requirement';
      return 'Verification Link';
    case 'HAS_TEST':
      if (currentType === 'TestGroup' && dir === 'out' && otherType === 'Test') return 'Contained Test';
      if (currentType === 'Test' && dir === 'in' && otherType === 'TestGroup') return 'Parent Test Group';
      return 'Test Containment';
    case 'MITIGATED_BY':
      if (currentType === 'Requirement' && dir === 'in' && otherType === 'Risk') return 'Mitigates Risk';
      if (currentType === 'Risk' && dir === 'out' && otherType === 'Requirement') return 'Mitigated By Requirement';
      return 'Risk Mitigation Link';
    case 'ALLOCATED_TO':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'DesignInput') return 'Allocated Design Input';
      if (currentType === 'DesignInput' && dir === 'in' && otherType === 'Requirement') return 'Allocated Requirement';
      return 'Allocation Link';
    case 'SATISFIED_BY':
      if (currentType === 'DesignInput' && dir === 'out' && otherType === 'DesignOutput') return 'Satisfied By Design Output';
      if (currentType === 'DesignOutput' && dir === 'in' && otherType === 'DesignInput') return 'Satisfies Design Input';
      return 'Satisfaction Link';
    case 'CONTROLLED_BY':
      if (currentType === 'DesignOutput' && dir === 'out' && otherType === 'ConfigurationItem') return 'Controlled Configuration Item';
      if (currentType === 'ConfigurationItem' && dir === 'in' && otherType === 'DesignOutput') return 'Controls Design Output';
      return 'Configuration Control Link';
    case 'IMPLEMENTED_IN':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'SourceFile') return 'Implemented In Source File';
      if (currentType === 'SourceFile' && dir === 'in' && otherType === 'Requirement') return 'Implements Requirement';
      if (currentType === 'DesignOutput' && dir === 'out' && otherType === 'SourceFile') return 'Implemented In Source File';
      if (currentType === 'SourceFile' && dir === 'in' && otherType === 'DesignOutput') return 'Implements Design Output';
      return 'Implementation Link';
    case 'VERIFIED_BY_CODE':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'TestFile') return 'Verified By Test File';
      if (currentType === 'TestFile' && dir === 'in' && otherType === 'Requirement') return 'Verifies Requirement';
      if (currentType === 'SourceFile' && dir === 'out' && otherType === 'TestFile') return 'Verified By Test File';
      if (currentType === 'TestFile' && dir === 'in' && otherType === 'SourceFile') return 'Verifies Source File';
      return 'Code Verification Link';
    case 'ANNOTATED_AT':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'CodeAnnotation') return 'Code Annotation';
      if (currentType === 'CodeAnnotation' && dir === 'in' && otherType === 'Requirement') return 'Annotated Requirement';
      return 'Annotation Link';
    case 'CONTAINS':
      if ((currentType === 'SourceFile' || currentType === 'TestFile') && dir === 'out' && otherType === 'CodeAnnotation') return 'Contained Annotation';
      if (currentType === 'CodeAnnotation' && dir === 'in' && (otherType === 'SourceFile' || otherType === 'TestFile')) return 'Contained In File';
      return 'Containment Link';
    case 'COMMITTED_IN':
      if (currentType === 'Requirement' && dir === 'out' && otherType === 'Commit') return 'Implementing Commit';
      if (currentType === 'Commit' && dir === 'in' && otherType === 'Requirement') return 'Implements Requirement';
      return 'Commit Link';
    default:
      return label.replaceAll('_', ' ');
  }
}

export function semanticEdgeDirection(currentType, edge, rawDir) {
  const relation = humanEdgeLabel(currentType, edge, rawDir);
  if (relation === 'Source User Need' || relation === 'Parent Requirement') return 'up';
  if (relation === 'Derived Requirement' || relation === 'Child Requirement') return 'down';
  return rawDir === 'out' ? 'down' : 'up';
}

export function splitSemanticEdges(currentType, edgesOut, edgesIn) {
  const upstream = [];
  const downstream = [];

  for (const edge of edgesOut) {
    const item = { edge, rawDir: 'out' };
    (semanticEdgeDirection(currentType, edge, 'out') === 'up' ? upstream : downstream).push(item);
  }
  for (const edge of edgesIn) {
    const item = { edge, rawDir: 'in' };
    (semanticEdgeDirection(currentType, edge, 'in') === 'up' ? upstream : downstream).push(item);
  }

  return { upstream, downstream };
}
