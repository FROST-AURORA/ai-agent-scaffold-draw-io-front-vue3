<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { getUserInfo, setUserInfo, clearUserInfo } from '@/utils/cookie'

const router = useRouter()

const username = ref('')
const password = ref('')
const showPassword = ref(false)
const msg = ref({ text: '', type: '' })
const isLoggedIn = ref(false)
const currentUser = ref('')
const isLoading = ref(false)

onMounted(() => {
  const userInfo = getUserInfo()
  if (userInfo && userInfo.user) {
    isLoggedIn.value = true
    currentUser.value = userInfo.user
    router.push('/')
  }
})

const handleLogin = () => {
  msg.value = { text: '', type: '' }

  if (!username.value || !password.value) {
    msg.value = { text: '请输入账号与密码。', type: 'error' }
    return
  }

  isLoading.value = true

  if (username.value !== 'admin' || password.value !== 'admin') {
    setTimeout(() => {
      msg.value = { text: '账号或密码错误（演示账号：admin / admin）。', type: 'error' }
      isLoading.value = false
    }, 600)
    return
  }

  setTimeout(() => {
    setUserInfo(username.value)
    msg.value = { text: '登录成功，正在跳转…', type: 'info' }
    router.push('/')
  }, 600)
}

const handleFillDemo = () => {
  username.value = 'admin'
  password.value = 'admin'
  msg.value = { text: '已填充演示账号。', type: 'info' }
}

const handleLogout = () => {
  clearUserInfo()
  isLoggedIn.value = false
  currentUser.value = ''
  msg.value = { text: '已退出登录，cookie 已清除。', type: 'info' }
}

const heroPreviewUrl = '/images/workbench-preview.jpg'
</script>

<template>
  <div class="min-h-full overflow-y-auto flex justify-center items-center p-4 sm:p-8 theme-bg-gradient">
    <div class="w-full max-w-[1160px] grid grid-cols-1 lg:grid-cols-[1.2fr_0.8fr] gap-6 lg:gap-10">
      <!-- Hero Section -->
      <section class="theme-card rounded-2xl overflow-hidden relative flex flex-col gap-[20px] p-[28px] backdrop-blur-xl border border-[rgba(255,255,255,0.14)] shadow-2xl">
        <div class="flex items-center gap-4">
          <div class="w-12 h-12 rounded-[16px] grid place-items-center bg-gradient-to-br from-[#62f6c7] to-[#5aa9ff] shadow-[0_10px_24px_rgba(98,246,199,0.3)] text-[#070a12] font-black text-xl tracking-wide">
            AI
          </div>
          <div class="flex flex-col gap-0.5">
            <strong class="text-lg leading-tight text-white">
              AI 智能体工作台 By Ai Agent Scaffold
            </strong>
            <span class="text-[13px] font-medium text-[#62f6c7]/80">@FA · 更快搭建 · 更稳运行 · 更易运维</span>
          </div>
        </div>

        <h1 class="mt-2 text-[32px] lg:text-[36px] leading-[1.25] tracking-tight text-white font-bold">
          一个能<span class="text-transparent bg-clip-text bg-gradient-to-r from-[#62f6c7] to-[#5aa9ff]">“帮你把事做完”</span>的智能体平台
        </h1>
        <p class="m-0 text-[rgba(255,255,255,0.7)] leading-[1.7] max-w-[56ch] text-[15px]">
          进入 AI 驱动的 draw.io 工作台，在画布中生成、调整并沉淀你的架构图。当前为演示登录：
          账号 <b class="text-white">admin</b>，密码 <b class="text-white">admin</b>。登录成功后将在浏览器端持久化保存状态。
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-2">
          <div v-for="(item, idx) in [
            { title: '工具调用编排', desc: '支持 API / Shell / 文件等执行链路高度自定义编排' },
            { title: '记忆与上下文机制', desc: '可配置可审计的上下文机制，大幅减少重复沟通成本' },
            { title: '多模型智能路由', desc: '根据任务场景自动选择最合适的底层模型与处理策略' },
            { title: '全链路可观测性', desc: '调用链路、Token成本、失败原因均可多维度追踪' }
          ]" :key="idx" class="border border-[rgba(255,255,255,0.06)] bg-[rgba(255,255,255,0.03)] hover:bg-[rgba(255,255,255,0.06)] transition-colors duration-300 rounded-[16px] p-4 flex gap-3 items-start group">
            <div class="w-2.5 h-2.5 rounded-full mt-1.5 flex-shrink-0 bg-gradient-to-br from-[#62f6c7] to-[#5aa9ff] shadow-[0_0_0_4px_rgba(98,246,199,0.1)] group-hover:shadow-[0_0_0_6px_rgba(98,246,199,0.15)] transition-all"></div>
            <div>
              <b class="block text-[14px] mb-1 text-[rgba(255,255,255,0.95)] tracking-wide">{{ item.title }}</b>
              <span class="block text-[13px] text-[rgba(255,255,255,0.5)] leading-[1.6]">{{ item.desc }}</span>
            </div>
          </div>
        </div>

        <div class="mt-4 rounded-2xl overflow-hidden border border-white/10 bg-black/30 h-[280px] lg:h-[340px] relative group shadow-[0_24px_60px_rgba(0,0,0,0.35)]">
           <img 
             :src="heroPreviewUrl"
             alt="AI 智能体绘图工作台预览"
             class="w-full h-full object-cover object-top opacity-95 group-hover:opacity-100 group-hover:scale-[1.025] transition-all duration-700 ease-out"
            />
           <div class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/75 via-black/20 to-transparent p-5">
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-white text-sm font-semibold backdrop-blur-md bg-white/10 px-3 py-1.5 rounded-lg border border-white/10">
                  真实工作台预览
                </span>
                <span class="text-white/70 text-xs backdrop-blur-md bg-black/20 px-2.5 py-1 rounded-md border border-white/10">
                  画布协作 · Agent 分析 · Markdown 回复
                </span>
              </div>
           </div>
        </div>
      </section>

      <!-- Login Form Section -->
      <section class="flex flex-col justify-center">
        <div class="theme-card rounded-2xl p-8 backdrop-blur-xl border border-[rgba(255,255,255,0.14)] shadow-2xl relative overflow-hidden">
          <!-- Decorative background glow -->
          <div class="absolute -top-20 -right-20 w-40 h-40 bg-[#5aa9ff] rounded-full blur-[80px] opacity-20 pointer-events-none"></div>
          <div class="absolute -bottom-20 -left-20 w-40 h-40 bg-[#62f6c7] rounded-full blur-[80px] opacity-20 pointer-events-none"></div>

          <div class="relative z-10">
            <h2 class="m-0 mb-2 text-[26px] text-white font-bold tracking-tight">欢迎登录</h2>
            <p class="m-0 mb-8 text-[rgba(255,255,255,0.5)] text-[14px] leading-[1.6]">
              演示账号：admin / admin <br/>（可在页面脚本中替换成真实鉴权接口）
            </p>

            <form v-if="!isLoggedIn" @submit.prevent="handleLogin" autocomplete="on" class="flex flex-col gap-5">
              <div class="flex flex-col gap-2">
                <label for="username" class="text-[13px] font-medium text-[rgba(255,255,255,0.8)] tracking-wide ml-1">
                  账号
                </label>
                <div class="relative group">
                  <div class="absolute left-3.5 top-1/2 -translate-y-1/2 text-[rgba(255,255,255,0.3)] group-focus-within:text-[#62f6c7] transition-colors duration-300">
                    <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2" />
                      <circle cx="12" cy="7" r="4" />
                    </svg>
                  </div>
                  <input
                    id="username"
                    type="text"
                    v-model="username"
                    placeholder="请输入账号"
                    autocomplete="username"
                    class="w-full rounded-[14px] theme-input py-3.5 pl-11 pr-4 outline-none transition-all duration-300 text-[15px] placeholder:text-[rgba(255,255,255,0.25)] hover:bg-[rgba(0,0,0,0.25)] focus:bg-[rgba(0,0,0,0.3)]"
                  />
                </div>
              </div>

              <div class="flex flex-col gap-2">
                <label for="password" class="text-[13px] font-medium text-[rgba(255,255,255,0.8)] tracking-wide ml-1">
                  密码
                </label>
                <div class="relative group">
                  <div class="absolute left-3.5 top-1/2 -translate-y-1/2 text-[rgba(255,255,255,0.3)] group-focus-within:text-[#62f6c7] transition-colors duration-300">
                    <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <rect width="18" height="11" x="3" y="11" rx="2" ry="2" />
                      <path d="M7 11V7a5 5 0 0 1 10 0v4" />
                    </svg>
                  </div>
                  <input
                    id="password"
                    :type="showPassword ? 'text' : 'password'"
                    v-model="password"
                    placeholder="请输入密码"
                    autocomplete="current-password"
                    class="w-full rounded-[14px] theme-input py-3.5 pl-11 pr-11 outline-none transition-all duration-300 text-[15px] placeholder:text-[rgba(255,255,255,0.25)] hover:bg-[rgba(0,0,0,0.25)] focus:bg-[rgba(0,0,0,0.3)]"
                  />
                  <button
                    type="button"
                    @click="showPassword = !showPassword"
                    class="absolute right-3.5 top-1/2 -translate-y-1/2 text-[rgba(255,255,255,0.3)] hover:text-white transition-colors duration-300 outline-none"
                  >
                    <svg v-if="!showPassword" xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
                      <circle cx="12" cy="12" r="3" />
                    </svg>
                    <svg v-else xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M9.88 9.88a3 3 0 1 0 4.24 4.24" />
                      <path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68" />
                      <path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61" />
                      <line x1="2" x2="22" y1="2" y2="22" />
                    </svg>
                  </button>
                </div>
              </div>

              <div class="flex flex-col gap-3 mt-4">
                <button 
                  type="submit" 
                  :disabled="isLoading"
                  class="theme-btn w-full rounded-[14px] py-[14px] px-6 font-bold cursor-pointer border-0 transition-all duration-300 hover:scale-[1.02] hover:shadow-[0_16px_32px_rgba(98,246,199,0.25)] active:scale-[0.98] text-[15px] flex items-center justify-center gap-2 disabled:opacity-70 disabled:cursor-not-allowed disabled:hover:scale-100"
                >
                  <template v-if="isLoading">验证中...</template>
                  <template v-else>
                    登录并保存 Cookie
                    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M5 12h14" />
                      <path d="m12 5 7 7-7 7" />
                    </svg>
                  </template>
                </button>
                <button 
                  type="button" 
                  @click="handleFillDemo" 
                  class="theme-btn-secondary w-full rounded-[14px] py-[12px] px-6 font-semibold cursor-pointer transition-all duration-300 hover:bg-[rgba(255,255,255,0.12)] active:scale-[0.98] text-[14px] flex items-center justify-center gap-2"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="m20.6 8.4-1.2-1.2a2.83 2.83 0 0 0-4 0l-5.6 5.6-2.6 7.6 7.6-2.6 5.6-5.6a2.83 2.83 0 0 0 0-4Z" />
                    <path d="m14 6 4 4" />
                    <path d="M3 21h18" />
                  </svg>
                  一键填充演示账号
                </button>
              </div>
            </form>

            <div v-else class="flex flex-col gap-4 p-5 border border-[rgba(255,255,255,0.1)] rounded-[16px] bg-[rgba(255,255,255,0.03)] backdrop-blur-md">
              <div class="flex items-center gap-4">
                <div class="w-12 h-12 rounded-full bg-gradient-to-tr from-[#62f6c7] to-[#5aa9ff] flex items-center justify-center text-[#070a12] font-bold text-xl shadow-lg">
                  {{ currentUser.charAt(0).toUpperCase() }}
                </div>
                <div>
                  <strong class="block text-[16px] text-white tracking-wide">已登录：{{ currentUser }}</strong>
                  <span class="block text-[13px] text-[rgba(255,255,255,0.5)] mt-1">欢迎回来，准备好开始工作了吗？</span>
                </div>
              </div>
              <button 
                @click="handleLogout" 
                class="theme-btn-secondary w-full mt-2 rounded-[12px] py-[10px] font-semibold cursor-pointer text-[14px] flex items-center justify-center gap-2 hover:bg-[rgba(255,58,90,0.1)] hover:text-[#ff5a7a] hover:border-[#ff5a7a]/30 transition-colors"
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
                  <polyline points="16 17 21 12 16 7" />
                  <line x1="21" x2="9" y1="12" y2="12" />
                </svg>
                退出登录
              </button>
            </div>

            <div :class="[
              'min-h-[20px] text-[13px] mt-5 font-medium text-center transition-opacity duration-300',
              msg.text ? 'opacity-100' : 'opacity-0',
              msg.type === 'error' ? 'text-[#ff5a7a]' : 'text-[#62f6c7]'
            ]">
              {{ msg.text }}
            </div>
          </div>
        </div>

        <div class="mt-8 text-[rgba(255,255,255,0.3)] text-[13px] text-center font-medium tracking-wide">
          © AI Agent Scaffold · Vue 3 页面示例
        </div>
      </section>
    </div>
  </div>
</template>
