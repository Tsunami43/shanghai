[
  # Ignore contract_supertype warnings (spec is more general than needed)
  ~r/Type specification is a supertype/,

  # Ignore extra_range warnings for placeholder implementations
  ~r/lib\/query\.ex.*extra_range/,
  ~r/lib\/storage\/compaction\/compactor\.ex.*extra_range/,

  # Ignore no_return warnings for display functions
  ~r/lib\/shanghaictl\/commands.*no_return/,

  # Ignore invalid_contract for internal state types
  ~r/lib\/storage\/index\/segment_index\.ex.*invalid_contract/
]
