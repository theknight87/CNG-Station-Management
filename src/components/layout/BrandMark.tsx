/**
 * Cargas / NGV brand marks.
 *
 * The official artwork is rendered as supplied. It is never recoloured, never
 * stretched, never redrawn, and never used as a decorative watermark: it
 * appears once per surface, as identification.
 *
 * Two assets, because one does not do both jobs:
 *
 * - `full` is the complete lockup (leaf device, Arabic wordmark, NGV), with the
 *   source PNG's transparent margin trimmed away. Trimming removes empty pixels
 *   only — no part of the artwork is altered — and without it the lockup floats
 *   inside 32px of nothing in a 48px-tall header.
 * - `mark` is the leaf device alone, cut from the official lockup at its own
 *   fully transparent seam (the blank row between the device and the NGV
 *   wordmark). At the collapsed sidebar's 52px the full lockup's wordmarks
 *   collapse into noise, so the device stands in for it. This is a crop of the
 *   supplied file, not a new mark.
 *
 * Both render with an explicit intrinsic width and height so the browser
 * reserves the right box before the image decodes (no layout shift), and both
 * size from HEIGHT with `w-auto`, so the aspect ratio cannot be squashed by a
 * parent.
 */
export function BrandMark({
  variant = 'full',
  className,
}: {
  variant?: 'full' | 'mark'
  className?: string
}) {
  const src = variant === 'full' ? '/brand/logo-trimmed.png' : '/brand/mark.png'
  const [w, h] = variant === 'full' ? [204, 232] : [204, 204]

  return (
    <img
      src={src}
      width={w}
      height={h}
      // The company name, not the file name. A screen-reader user needs to know
      // whose system this is; the product name is beside it in real text.
      alt="Cargas NGV"
      className={className}
      // Decorative-adjacent but identifying: keep it in the accessibility tree.
      draggable={false}
    />
  )
}
