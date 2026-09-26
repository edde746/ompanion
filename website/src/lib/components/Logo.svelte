<script lang="ts">
  import glyph from '$lib/assets/glyph.svg';

  const { size = 28 }: { size?: number } = $props();
</script>

<img src={glyph} alt="" width={size} height={size} />
