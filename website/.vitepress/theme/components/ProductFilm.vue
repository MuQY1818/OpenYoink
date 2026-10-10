<script setup lang="ts">
import { computed } from 'vue'
import { withBase } from 'vitepress'

const props = withDefaults(defineProps<{ language?: 'zh' | 'en' }>(), { language: 'zh' })
const copy = computed(() => props.language === 'en' ? {
  title: 'Less switching. More doing.',
  label: 'Watch the OpenYoink product film',
  description: 'From parking a file to media controls, system status and clipboard history.',
  note: 'An animated interface demonstration with example files and readings.',
  open: 'Open video',
  credits: 'Music credits',
  edits: 'Edited for length, fades and loudness.',
  recording: 'Watch the original screen recording',
  fallback: 'Your browser cannot play this video.'
} : {
  title: '少一点切换，多一点顺手。',
  label: '播放 OpenYoink 产品短片',
  description: '暂存文件、控制音乐、查看系统状态，再找回刚才复制的内容。',
  note: '界面动效演示，文件与读数为示例。',
  open: '单独打开视频',
  credits: '配乐署名',
  edits: '已做时长剪辑、淡入淡出与响度调整。',
  recording: '查看原始使用录屏',
  fallback: '当前浏览器无法播放此视频。'
})
</script>

<template>
  <figure id="film" class="product-film">
    <div class="film-frame">
      <div class="film-bar">
        <span>OPENYOINK FILM</span>
        <span>00:40 · 1080p</span>
      </div>
      <video
        :src="withBase('/videos/openyoink-promo-v5.mp4')"
        :poster="withBase('/videos/openyoink-promo-v5-poster.jpg')"
        :aria-label="copy.label"
        aria-describedby="film-caption"
        width="1920"
        height="1080"
        controls
        playsinline
        preload="none"
      >
        <track kind="captions" :src="withBase('/videos/openyoink-promo-v5.en.vtt')" srclang="en" label="English">
        <track kind="captions" :src="withBase('/videos/openyoink-promo-v5.zh.vtt')" srclang="zh-CN" label="简体中文">
        {{ copy.fallback }}
        <a :href="withBase('/videos/openyoink-promo-v5.mp4')">{{ copy.open }}</a>
      </video>
    </div>
    <figcaption id="film-caption" class="film-caption">
      <div>
        <strong>{{ copy.title }}</strong>
        <p>{{ copy.description }}</p>
      </div>
      <a class="film-open" :href="withBase('/videos/openyoink-promo-v5.mp4')">{{ copy.open }} <span aria-hidden="true">↗</span></a>
    </figcaption>
    <div class="film-notes">
      <span>{{ copy.note }}</span>
      <a :href="withBase('/images/usage-demo.mp4')">{{ copy.recording }}</a>
      <details class="film-credits">
        <summary>{{ copy.credits }}</summary>
        <p>
          “<a href="https://www.scottbuckley.com.au/library/origami/">Origami</a>” by
          <a href="https://www.scottbuckley.com.au/">Scott Buckley</a> ·
          <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a>.
          {{ copy.edits }}
        </p>
      </details>
    </div>
  </figure>
</template>

<style scoped>
.product-film {
  max-width: 940px;
  margin: 72px auto 0;
  scroll-margin-top: 100px;
  text-align: left;
  color: var(--oy-ink);
}
.film-frame {
  overflow: hidden;
  border: 1px solid var(--oy-line-strong);
  border-radius: 18px;
  background: #090b0d;
  box-shadow: 0 24px 64px #00000026;
}
.film-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 12px 18px;
  border-bottom: 1px solid #ffffff14;
  color: #a0acb2;
  font: 11px/1.5 var(--vp-font-family-mono);
  letter-spacing: .05em;
}
.film-frame video {
  display: block;
  width: 100%;
  height: auto;
  aspect-ratio: 16 / 9;
  object-fit: contain;
  background: #090b0d;
}
.film-frame video:focus-visible,
.product-film a:focus-visible,
.film-credits summary:focus-visible {
  outline: 3px solid var(--oy-blue);
  outline-offset: 4px;
}
.film-caption {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 20px;
  padding: 22px 0 14px;
}
.film-caption strong { font-size: 20px; line-height: 1.5; font-weight: 650; }
.film-caption p { margin: 6px 0 0; font-size: 14px; line-height: 1.7; color: var(--oy-muted); }
.product-film a { color: var(--oy-blue); text-decoration: none; }
.product-film a:hover { text-decoration: underline; text-underline-offset: 3px; }
.film-open { flex-shrink: 0; margin-top: 4px; font-size: 13px; line-height: 1.8; }
.film-notes {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 8px 18px;
  border-top: 1px solid var(--oy-line);
  padding-top: 14px;
  font-size: 12px;
  line-height: 1.7;
  color: var(--oy-muted);
}
.film-credits { flex: 1; min-width: 92px; }
.film-credits summary { cursor: pointer; width: fit-content; }
.film-credits p { margin: 8px 0 0; font-size: 12px; line-height: 1.7; }
@media (max-width: 720px) {
  .product-film { margin-top: 48px; }
  .film-frame { border-radius: 12px; }
  .film-bar { padding: 10px 12px; font-size: 10px; }
  .film-caption { flex-direction: column; gap: 8px; padding-top: 18px; }
  .film-caption strong { font-size: 18px; }
}
</style>
