<script setup lang="ts">
import { ref, onMounted, onBeforeUpdate, watch, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { DrawIoEmbed } from 'vue-drawio'
import type { DrawIoEmbedRef } from 'vue-drawio'
import { Marked, type Tokens } from 'marked'
import DOMPurify from 'dompurify'
import hljs from 'highlight.js'
import 'highlight.js/styles/atom-one-dark.css'
import { getUserInfo, clearUserInfo } from '@/utils/cookie'
import { agentApi } from '@/api/agent'
import type { AiAgentConfigResponseDTO } from '@/types/api'

// Define Types
type Message = {
  id: string
  role: 'user' | 'agent'
  content: string
  thinkingContent?: string
  answerContent?: string
  timestamp: number
}

interface Session {
  id: string
  backendSessionId?: string
  title: string
  messages: Message[]
  drawIoXml: string | null
  lastModified: number
}

type ChatResponsePayload = {
  type?: string
  content?: string
  user?: string
  drawio?: string
  drawIoXml?: string
  drawioXml?: string
  xml?: string
  message?: string
}

type NormalizedChatResponse = {
  userContent?: string
  drawIoXml?: string
}

type AgentMessageSectionKind = 'thinking' | 'generation' | 'final' | 'error'

type AgentMessageSection = {
  kind: AgentMessageSectionKind
  statusText: string
  title: string
  content: string
}

type ChatMode = 'normal' | 'stream'

type StreamEventPayload = {
  type?: 'status' | 'delta' | 'final' | 'done' | 'error' | string
  content?: string
}

type StreamingResponseResult = {
  streamText: string
  error?: string
}

const markdownParser = new Marked({
  async: false,
  walkTokens(token) {
    if (token.type !== 'code') return

    const codeToken = token as Tokens.Code
    if (!codeToken.lang || !hljs.getLanguage(codeToken.lang)) return

    try {
      codeToken.text = hljs.highlight(codeToken.text, { language: codeToken.lang }).value
      codeToken.escaped = true
    } catch {
      // Leave the original escaped code block when highlight.js cannot parse it.
    }
  },
})

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === 'object' && value !== null
}

const getStringField = (payload: Record<string, unknown>, fields: string[]) => {
  for (const field of fields) {
    const value = payload[field]
    if (typeof value === 'string' && value.trim()) {
      return value
    }
  }
  return undefined
}

const stripMarkdownFence = (value: string) => {
  const trimmed = value.trim()
  const fenced = trimmed.match(/^```(?:json|xml)?\s*([\s\S]*?)\s*```$/i)
  return fenced && fenced[1] ? fenced[1].trim() : trimmed
}

const parseJsonString = (value?: string) => {
  if (!value) return undefined
  const stripped = stripMarkdownFence(value)
  try {
    const parsed = JSON.parse(stripped)
    return isRecord(parsed) ? parsed : undefined
  } catch {
    return undefined
  }
}

const parseStreamEvent = (rawEvent: string): StreamEventPayload | undefined => {
  const dataLines = rawEvent
    .split(/\r?\n/)
    .map(line => line.trimEnd())
    .filter(line => line.startsWith('data:'))
    .map(line => line.replace(/^data:\s?/, ''))

  if (dataLines.length === 0) {
    return undefined
  }

  const data = dataLines.join('\n').trim()
  if (!data || data === '[DONE]') {
    return { type: 'done', content: '' }
  }

  try {
    const parsed = JSON.parse(data)
    if (isRecord(parsed)) {
      return {
        type: typeof parsed.type === 'string' ? parsed.type : 'delta',
        content: typeof parsed.content === 'string' ? parsed.content : '',
      }
    }
  } catch {
    return { type: 'delta', content: data }
  }

  return undefined
}

const extractDrawIoXml = (value?: string) => {
  if (!value) return undefined
  const stripped = stripMarkdownFence(value)
  const xmlFence = stripped.match(/```xml\s*([\s\S]*?)\s*```/i)
  const source = xmlFence && xmlFence[1] ? xmlFence[1].trim() : stripped

  const mxFile = source.match(/(?:<\?xml[\s\S]*?\?>\s*)?<mxfile[\s\S]*?<\/mxfile>/i)
  if (mxFile) return mxFile[0].trim()

  const mxGraphModel = source.match(/(?:<\?xml[\s\S]*?\?>\s*)?<mxGraphModel[\s\S]*?<\/mxGraphModel>/i)
  if (mxGraphModel) return mxGraphModel[0].trim()

  return undefined
}

const removeDrawIoXmlFromText = (value?: string) => {
  if (!value) return undefined
  const withoutXmlFence = value.replace(/```xml\s*[\s\S]*?\s*```/gi, '').trim()
  const withoutMxFile = withoutXmlFence
    .replace(/(?:<\?xml[\s\S]*?\?>\s*)?<mxfile[\s\S]*?<\/mxfile>/gi, '')
    .replace(/(?:<\?xml[\s\S]*?\?>\s*)?<mxGraphModel[\s\S]*?<\/mxGraphModel>/gi, '')
    .trim()
  return withoutMxFile || undefined
}

const normalizeChatResponse = (payload: ChatResponsePayload): NormalizedChatResponse => {
  const response = payload as Record<string, unknown>
  const content = typeof payload.content === 'string' ? payload.content : undefined
  const contentJson = parseJsonString(content)
  const source = contentJson ?? response

  const userContent = getStringField(source, ['user', 'message', 'answer', 'content'])
  const drawIoCandidate = getStringField(source, ['drawio', 'drawIoXml', 'drawioXml', 'xml', 'diagram'])
  const drawIoXml =
    extractDrawIoXml(drawIoCandidate) ??
    (payload.type === 'drawio' ? extractDrawIoXml(content) : undefined) ??
    extractDrawIoXml(content)

  if (contentJson) {
    return {
      userContent: removeDrawIoXmlFromText(userContent),
      drawIoXml,
    }
  }

  if (payload.type === 'drawio') {
    return { drawIoXml: drawIoXml ?? content?.trim() }
  }

  return {
    userContent: removeDrawIoXmlFromText(userContent ?? content),
    drawIoXml,
  }
}

const getAgentSectionMeta = (content: string) => {
  if (content.startsWith('请求失败：') || content.startsWith('Error:')) {
    return {
      kind: 'error' as const,
      statusText: '请求异常',
      title: '接口错误',
    }
  }

  if (content.includes('agent_analyst')) {
    return {
      kind: 'thinking' as const,
      statusText: '思考中',
      title: '需求分析',
    }
  }

  if (content.includes('agent_drawer')) {
    return {
      kind: 'generation' as const,
      statusText: '生成中',
      title: '绘图生成',
    }
  }

  if (content.includes('agent_reviewer')) {
    return {
      kind: 'final' as const,
      statusText: '回答结果',
      title: '质量检查',
    }
  }

  return {
    kind: 'final' as const,
    statusText: '回答结果',
    title: 'Agent 回复',
  }
}

const splitAgentMessageSections = (content: string): AgentMessageSection[] => {
  const markerPattern = /你好！我是\s+\*\*(?:需求分析师|agent_drawer|agent_reviewer)[\s\S]{0,140}?(?:agent_analyst|agent_drawer|agent_reviewer)/g
  const matches = Array.from(content.matchAll(markerPattern))

  if (matches.length === 0) {
    const meta = getAgentSectionMeta(content)
    return [{ ...meta, content }]
  }

  const starts = matches.map(match => match.index ?? 0)
  const sections: AgentMessageSection[] = []

  if (starts.length > 0 && starts[0] !== undefined && starts[0] > 0) {
    const prefix = content.slice(0, starts[0]).trim()
    if (prefix) {
      const meta = getAgentSectionMeta(prefix)
      sections.push({ ...meta, content: prefix })
    }
  }

  starts.forEach((start, index) => {
    const end = starts[index + 1] ?? content.length
    const sectionContent = content.slice(start, end).trim()
    if (sectionContent) {
      const meta = getAgentSectionMeta(sectionContent)
      sections.push({ ...meta, content: sectionContent })
    }
  })

  return sections
}

const mergeProcessSections = (sections: AgentMessageSection[]) => {
  return sections.reduce<AgentMessageSection[]>((merged, section) => {
    const previous = merged[merged.length - 1]
    const isProcess = section.kind === 'thinking' || section.kind === 'generation'
    const previousIsProcess = previous?.kind === 'thinking' || previous?.kind === 'generation'

    if (isProcess && previousIsProcess) {
      merged[merged.length - 1] = {
        ...previous,
        content: `${previous.content}\n\n${section.content}`,
      }
      return merged
    }

    merged.push(section)
    return merged
  }, [])
}

const exportDiagramXml = (drawio: DrawIoEmbedRef | null) => {
  const exportDiagram = drawio?.exportDiagram as ((data: { format: 'xml' }) => void) | undefined
  exportDiagram?.({ format: 'xml' })
}

const renderMarkdown = (text: string) => {
  if (!text) return ''
  const rawHtml = markdownParser.parse(text, { async: false })
  return DOMPurify.sanitize(enhanceCodeBlocks(rawHtml))
}

const enhanceCodeBlocks = (html: string) => {
  if (typeof document === 'undefined') return html

  const template = document.createElement('template')
  template.innerHTML = html

  template.content.querySelectorAll('pre').forEach(pre => {
    const code = pre.querySelector('code')
    const languageClass = Array.from(code?.classList ?? []).find(className => className.startsWith('language-'))
    const language = languageClass?.replace('language-', '') || 'code'

    const wrapper = document.createElement('div')
    wrapper.className = 'markdown-code-block'

    const header = document.createElement('div')
    header.className = 'markdown-code-header'

    const label = document.createElement('span')
    label.className = 'markdown-code-language'
    label.textContent = language

    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'markdown-code-copy'
    button.textContent = '复制'

    header.append(label, button)
    pre.replaceWith(wrapper)
    wrapper.append(header, pre)
  })

  return template.innerHTML
}

const handleMarkdownClick = async (event: MouseEvent) => {
  const target = event.target as HTMLElement | null
  const copyButton = target?.closest<HTMLButtonElement>('.markdown-code-copy')
  if (!copyButton) return

  const code = copyButton
    .closest('.markdown-code-block')
    ?.querySelector('pre code')
    ?.textContent

  if (!code) return

  try {
    await navigator.clipboard.writeText(code)
    copyButton.textContent = '已复制'
    copyButton.disabled = true
    window.setTimeout(() => {
      copyButton.textContent = '复制'
      copyButton.disabled = false
    }, 1200)
  } catch {
    copyButton.textContent = '复制失败'
    window.setTimeout(() => {
      copyButton.textContent = '复制'
    }, 1200)
  }
}

// Vue Component Setup
const router = useRouter()
const imgData = ref<string | null>(null)
const drawioRef = ref<DrawIoEmbedRef | null>(null)
const processContentRefs = ref<HTMLDivElement[]>([])

// User State
const currentUser = ref('')

// Chat State
const isChatOpen = ref(true)
const messages = ref<Message[]>([
  {
    id: '1',
    role: 'agent',
    content: '你好，我是你的智能绘图助手。请选择一个智能体开始对话。',
    timestamp: Date.now()
  }
])
const inputValue = ref('')
const isSending = ref(false)
const messagesEndRef = ref<HTMLDivElement | null>(null)

// Context State
const useHistoryContext = ref(false)
const chatMode = ref<ChatMode>('normal')
const lastExportedData = ref<{data: string, timestamp: number} | null>(null)
const isExportingForChatRef = ref(false)
const isAutosaveRef = ref(false)
const pendingMessageRef = ref('')
const isDrawIoReady = ref(false)
const initialLoadDoneRef = ref(false)

// Agent State
const agents = ref<AiAgentConfigResponseDTO[]>([])
const selectedAgentId = ref('')
const sessionId = ref('')

// Rename State
const isRenameModalOpen = ref(false)
const renamingSessionId = ref<string | null>(null)
const newSessionTitle = ref('')

// Session Management State
const sessions = ref<Session[]>([])
const currentSessionId = ref<string | null>(null)
const currentSessionRef = ref<string | null>(null)

// Computed for sections inside message
const getSectionsForMessage = (msg: Message, isActiveAgentMessage: boolean) => {
  const hasStructuredContent = Boolean(msg.thinkingContent || msg.answerContent)
  const rawSections = hasStructuredContent
    ? [
      ...(msg.thinkingContent
        ? [{
          kind: 'thinking' as const,
          statusText: '思考中',
          title: '思考过程',
          content: msg.thinkingContent,
        }]
        : []),
      ...(msg.answerContent
        ? [{
          kind: msg.answerContent.startsWith('Error:') || msg.answerContent.startsWith('请求失败：') ? 'error' as const : 'final' as const,
          statusText: '回答结果',
          title: '回答结果',
          content: msg.answerContent,
        }]
        : []),
    ]
    : splitAgentMessageSections(msg.content)

  const activeSections =
    isActiveAgentMessage && rawSections.length === 1 && rawSections[0]?.kind === 'final'
      ? [{ ...rawSections[0], kind: 'thinking' as const, statusText: '思考中' }] as AgentMessageSection[]
      : rawSections as AgentMessageSection[]

  return mergeProcessSections(activeSections)
}

watch(currentSessionId, (newVal) => {
  currentSessionRef.value = newVal
})

watch([isDrawIoReady, currentSessionId, sessions], () => {
  if (!initialLoadDoneRef.value && isDrawIoReady.value && currentSessionId.value && sessions.value.length > 0) {
    const session = sessions.value.find(s => s.id === currentSessionId.value)
    if (session && session.drawIoXml && drawioRef.value) {
      drawioRef.value.load({ xml: session.drawIoXml })
    }
    initialLoadDoneRef.value = true
  }
}, { deep: true })

onMounted(() => {
  const savedSessions = localStorage.getItem('drawio_sessions')
  if (savedSessions) {
    try {
      const parsed = JSON.parse(savedSessions)
      sessions.value = parsed
      if (parsed.length > 0) {
        const mostRecent = parsed.sort((a: Session, b: Session) => b.lastModified - a.lastModified)[0]
        currentSessionId.value = mostRecent.id
        messages.value = mostRecent.messages
      } else {
        createNewSession(true)
      }
    } catch (e) {
      console.error('Failed to parse sessions:', e)
      createNewSession(true)
    }
  } else {
    createNewSession(true)
  }
})

watch(sessions, (newVal) => {
  if (newVal.length > 0) {
    try {
      localStorage.setItem('drawio_sessions', JSON.stringify(newVal))
    } catch (e) {
      console.error('Failed to save sessions to localStorage:', e)
    }
  }
}, { deep: true })

watch([messages, currentSessionId, sessionId], () => {
  if (currentSessionId.value) {
    sessions.value = sessions.value.map(session => {
      if (session.id === currentSessionId.value) {
        return {
          ...session,
          messages: messages.value,
          backendSessionId: sessionId.value,
          title: session.title === 'New Chat' && messages.value.find(m => m.role === 'user')
            ? (messages.value.find(m => m.role === 'user')?.content.slice(0, 20) || 'New Chat')
            : session.title
        }
      }
      return session
    })
  }
}, { deep: true })

const createNewSession = (isInitial = false, backendId = '') => {
  const newSession: Session = {
    id: Date.now().toString(),
    backendSessionId: backendId,
    title: 'New Chat',
    messages: [{
      id: Date.now().toString(),
      role: 'agent',
      content: '你好，我是你的智能绘图助手。请选择一个智能体开始对话。',
      timestamp: Date.now()
    }],
    drawIoXml: null,
    lastModified: Date.now()
  }

  sessions.value = [newSession, ...sessions.value]
  currentSessionId.value = newSession.id
  messages.value = newSession.messages
  sessionId.value = backendId

  if (!isInitial && drawioRef.value) {
    drawioRef.value.load({ xml: '' })
  }
}

const handleSwitchSession = (targetSessionId: string) => {
  if (targetSessionId === currentSessionId.value) return
  loadSession(targetSessionId)
}

const loadSession = (targetSessionId: string) => {
  const session = sessions.value.find(s => s.id === targetSessionId)
  if (session) {
    currentSessionId.value = targetSessionId
    messages.value = session.messages
    sessionId.value = session.backendSessionId || ''
    if (drawioRef.value && session.drawIoXml) {
      drawioRef.value.load({ xml: session.drawIoXml })
    } else if (drawioRef.value) {
      drawioRef.value.load({ xml: '' })
    }
  }
}

const handleDeleteSession = (e: MouseEvent, sessionIdToDelete: string) => {
  e.stopPropagation()
  const newSessions = sessions.value.filter(s => s.id !== sessionIdToDelete)
  sessions.value = newSessions
  localStorage.setItem('drawio_sessions', JSON.stringify(newSessions))

  if (currentSessionId.value === sessionIdToDelete) {
    if (newSessions.length > 0 && newSessions[0]) {
      loadSession(newSessions[0].id)
    } else {
      createNewSession()
    }
  }
}

const handleDoubleClickSession = (session: Session) => {
  renamingSessionId.value = session.id
  newSessionTitle.value = session.title
  isRenameModalOpen.value = true
}

const handleRenameSave = () => {
  if (renamingSessionId.value && newSessionTitle.value.trim()) {
    sessions.value = sessions.value.map(s =>
      s.id === renamingSessionId.value ? { ...s, title: newSessionTitle.value.trim() } : s
    )
    isRenameModalOpen.value = false
    renamingSessionId.value = null
    newSessionTitle.value = ''
  }
}

const exportDiagram = () => {
  if (drawioRef.value) {
    drawioRef.value.exportDiagram({
      format: 'xmlsvg'
    })
  }
}

onBeforeUpdate(() => {
  processContentRefs.value = []
})

const scrollProcessContentToBottom = () => {
  const liveRefs = processContentRefs.value.filter((element): element is HTMLDivElement => {
    return Boolean(element?.isConnected)
  })

  let targetRef: HTMLDivElement | undefined
  for (let index = liveRefs.length - 1; index >= 0; index -= 1) {
    if (liveRefs[index]?.dataset.activeProcess === 'true') {
      targetRef = liveRefs[index]
      break
    }
  }

  targetRef ??= liveRefs[liveRefs.length - 1]
  if (!targetRef) return

  targetRef.scrollTo({
    top: targetRef.scrollHeight,
    behavior: 'auto',
  })
}

const scrollToBottom = () => {
  if (messagesEndRef.value) {
    messagesEndRef.value.scrollIntoView({
      behavior: isSending.value ? 'auto' : 'smooth',
      block: 'end',
    })
  }

  scrollProcessContentToBottom()
  requestAnimationFrame(scrollProcessContentToBottom)
}

watch([messages, isChatOpen], () => {
  nextTick(() => {
    scrollToBottom()
  })
}, { deep: true })

onMounted(() => {
  const userInfo = getUserInfo()
  if (!userInfo || !userInfo.user) {
    router.push('/login')
    return
  }
  currentUser.value = userInfo.user

  const loadAgents = async () => {
    try {
      const res = await agentApi.queryAiAgentConfigList()
      agents.value = res.data || []
      if (res.data && res.data.length > 0) {
        const lastAgentId = localStorage.getItem('ai_agent_last_agent')
        if (lastAgentId && res.data.find(a => a.agentId === lastAgentId)) {
          selectedAgentId.value = lastAgentId
        } else if (res.data[0]) {
          selectedAgentId.value = res.data[0].agentId
        }
      }
    } catch (error) {
      console.error('Failed to load agents:', error)
      messages.value.push({
        id: Date.now().toString(),
        role: 'agent',
        content: '加载智能体列表失败，请检查后端服务是否启动。',
        timestamp: Date.now()
      })
    }
  }
  loadAgents()
})

const handleLogout = () => {
  clearUserInfo()
  router.push('/login')
}

const handleAgentChange = (e: Event) => {
  const target = e.target as HTMLSelectElement
  const newAgentId = target.value
  selectedAgentId.value = newAgentId
  sessionId.value = ''
  localStorage.setItem('ai_agent_last_agent', newAgentId)
}

const finalizeNewChat = async () => {
  if (!selectedAgentId.value || !currentUser.value) return

  try {
    const res = await agentApi.createSession(selectedAgentId.value, currentUser.value)
    createNewSession(false, res.data.sessionId)
    inputValue.value = ''
  } catch (error) {
    console.error('Failed to create new session:', error)
  }
}

const handleNewChat = async () => {
  finalizeNewChat()
}

const handleRestartSession = async () => {
  if (!selectedAgentId.value || !currentUser.value) return

  if (!currentSessionId.value) {
    finalizeNewChat()
    return
  }

  try {
    const res = await agentApi.createSession(selectedAgentId.value, currentUser.value)
    const newBackendId = res.data.sessionId

    const initialMsg: Message = {
      id: Date.now().toString(),
      role: 'agent',
      content: '你好，我是你的智能绘图助手。请选择一个智能体开始对话。',
      timestamp: Date.now()
    }

    sessionId.value = newBackendId
    messages.value = [initialMsg]
    inputValue.value = ''

    sessions.value = sessions.value.map(session => {
      if (session.id === currentSessionId.value) {
        return {
          ...session,
          backendSessionId: newBackendId,
          messages: [initialMsg],
          lastModified: Date.now()
        }
      }
      return session
    })
  } catch (error) {
    console.error('Failed to restart session:', error)
  }
}

const updateAgentThinkingMessage = (messageId: string, thinkingContent: string) => {
  messages.value = messages.value.map(message =>
    message.id === messageId
      ? {
        ...message,
        thinkingContent,
        content: message.answerContent || thinkingContent,
      }
      : message
  )
}

const updateAgentAnswerMessage = (messageId: string, answerContent: string) => {
  messages.value = messages.value.map(message =>
    message.id === messageId
      ? {
        ...message,
        answerContent,
        content: answerContent || message.thinkingContent || message.content,
      }
      : message
  )
}

const applyDrawIoXml = (drawIoXml: string, requestSessionId: string | null) => {
  sessions.value = sessions.value.map(session => {
    if (session.id === requestSessionId) {
      return {
        ...session,
        drawIoXml,
        lastModified: Date.now()
      }
    }
    return session
  })

  if (drawioRef.value && requestSessionId === currentSessionRef.value) {
    try {
      drawioRef.value.load({
        xml: drawIoXml
      })
    } catch (e) {
      console.error('Failed to load diagram:', e)
    }
  }
}

const applyNormalizedChatResponse = (
  normalizedResponse: NormalizedChatResponse,
  requestSessionId: string | null,
  messageId?: string
) => {
  if (normalizedResponse.userContent) {
    if (messageId) {
      updateAgentAnswerMessage(messageId, normalizedResponse.userContent)
    } else {
      const agentMsg: Message = {
        id: (Date.now() + 1).toString(),
        role: 'agent',
        content: normalizedResponse.userContent,
        answerContent: normalizedResponse.userContent,
        timestamp: Date.now()
      }
      messages.value.push(agentMsg)
    }
  } else if (normalizedResponse.drawIoXml) {
    const diagramMessage = '图表已生成并更新到画布。'
    if (messageId) {
      updateAgentAnswerMessage(messageId, diagramMessage)
    } else {
      const agentMsg: Message = {
        id: (Date.now() + 1).toString(),
        role: 'agent',
        content: diagramMessage,
        answerContent: diagramMessage,
        timestamp: Date.now()
      }
      messages.value.push(agentMsg)
    }
  }

  if (normalizedResponse.drawIoXml) {
    applyDrawIoXml(normalizedResponse.drawIoXml, requestSessionId)
  }
}

const readStreamingResponse = async (response: globalThis.Response, messageId: string): Promise<StreamingResponseResult> => {
  const reader = response.body?.getReader()
  if (!reader) {
    throw new Error('Streaming response is not readable')
  }

  const decoder = new TextDecoder()
  let eventBuffer = ''
  let streamText = ''
  let visibleText = ''
  let streamError: string | undefined

  const handlePayload = (payload?: StreamEventPayload) => {
    if (!payload) return

    const content = payload.content ?? ''
    if (payload.type === 'status') {
      if (!visibleText) {
        updateAgentThinkingMessage(messageId, content)
      }
      return
    }

    if (payload.type === 'done') {
      return
    }

    if (payload.type === 'error') {
      streamError = content || 'Streaming response failed'
      const errorText = `请求失败：${streamError}`
      updateAgentAnswerMessage(messageId, errorText)
      return
    }

    if (payload.type === 'final') {
      streamText = content
      const answerText = removeDrawIoXmlFromText(content)
      if (answerText) {
        updateAgentAnswerMessage(messageId, answerText)
      }
      return
    }

    streamText += content
    visibleText += removeDrawIoXmlFromText(content) ?? content
    updateAgentThinkingMessage(messageId, visibleText)
  }

  const processEvents = (flush = false) => {
    if (flush) {
      const rawBuffer = eventBuffer
      eventBuffer = ''
      for (const part of rawBuffer.split(/\r?\n\r?\n/)) {
        if (part.trim()) {
          handlePayload(parseStreamEvent(part))
        }
      }
      return
    }

    const parts = eventBuffer.split(/\r?\n\r?\n/)
    eventBuffer = parts.pop() ?? ''

    for (const part of parts) {
      if (part.trim()) {
        handlePayload(parseStreamEvent(part))
      }
    }
  }

  while (true) {
    const { value, done } = await reader.read()
    if (done) break

    const chunk = decoder.decode(value, { stream: true })
    if (chunk) {
      eventBuffer += chunk
      processEvents()
    }
  }

  const finalChunk = decoder.decode()
  if (finalChunk) {
    eventBuffer += finalChunk
  }
  processEvents(true)

  return { streamText, error: streamError }
}

const performSendMessage = async (displayContent: string, apiContent: string) => {
  if (!selectedAgentId.value) {
    messages.value.push({
      id: Date.now().toString(),
      role: 'agent',
      content: '请先选择一个智能体。',
      timestamp: Date.now()
    })
    isSending.value = false
    return
  }

  const userMsg: Message = {
    id: Date.now().toString(),
    role: 'user',
    content: displayContent,
    timestamp: Date.now()
  }
  messages.value.push(userMsg)

  let pendingAgentMessageId: string | undefined

  try {
    const requestSessionId = currentSessionId.value

    let activeBackendSessionId = sessionId.value
    if (!activeBackendSessionId) {
      const sessionRes = await agentApi.createSession(selectedAgentId.value, currentUser.value)
      activeBackendSessionId = sessionRes.data.sessionId
      sessionId.value = activeBackendSessionId
    }

    sessions.value = sessions.value.map(session => {
      if (session.id === currentSessionId.value) {
        return { ...session, lastModified: Date.now() }
      }
      return session
    })

    const requestPayload = {
      agentId: selectedAgentId.value,
      userId: currentUser.value,
      sessionId: activeBackendSessionId,
      message: apiContent
    }

    if (chatMode.value === 'stream') {
      const streamMessageId = (Date.now() + 1).toString()
      pendingAgentMessageId = streamMessageId
      const streamMsg: Message = {
        id: streamMessageId,
        role: 'agent',
        content: '',
        timestamp: Date.now()
      }
      messages.value.push(streamMsg)

      const response = await agentApi.chatStream(requestPayload)
      const { streamText, error } = await readStreamingResponse(response, streamMessageId)
      if (error) {
        return
      }
      const normalizedResponse = normalizeChatResponse({ content: streamText })
      applyNormalizedChatResponse(normalizedResponse, requestSessionId, streamMessageId)
    } else {
      const normalMessageId = (Date.now() + 1).toString()
      pendingAgentMessageId = normalMessageId
      const waitingContent = '普通模式请求已提交，AI 正在完整生成回复，请稍候...'
      const waitingMsg: Message = {
        id: normalMessageId,
        role: 'agent',
        content: waitingContent,
        thinkingContent: waitingContent,
        timestamp: Date.now()
      }
      messages.value.push(waitingMsg)

      const chatRes = await agentApi.chat(requestPayload)
      const normalizedResponse = normalizeChatResponse(chatRes.data)

      applyNormalizedChatResponse(normalizedResponse, requestSessionId, normalMessageId)
    }

  } catch (error) {
    console.warn('Chat error:', error)
    const errorContent = error instanceof Error ? `Error: ${error.message}` : '发送失败，请重试。'
    if (pendingAgentMessageId) {
      updateAgentAnswerMessage(pendingAgentMessageId, errorContent)
      return
    }
    const errorMsg: Message = {
      id: (Date.now() + 1).toString(),
      role: 'agent',
      content: errorContent,
      answerContent: errorContent,
      timestamp: Date.now()
    }
    messages.value.push(errorMsg)
  } finally {
    isSending.value = false
  }
}

const handleSendMessage = async () => {
  if (!inputValue.value.trim() || isSending.value) return

  const content = inputValue.value
  inputValue.value = ''
  isSending.value = true

  if (useHistoryContext.value && drawioRef.value && isDrawIoReady.value) {
    isExportingForChatRef.value = true
    pendingMessageRef.value = content
    try {
      exportDiagramXml(drawioRef.value)
    } catch (e) {
      console.error("Export failed", e)
      performSendMessage(content, content)
    }
  } else {
    performSendMessage(content, content)
  }
}

watch(lastExportedData, (newVal) => {
  if (!newVal) return

  if (isExportingForChatRef.value) {
    isExportingForChatRef.value = false
    const content = pendingMessageRef.value
    const apiContent = buildMessageWithDrawIoContext(content, newVal.data)
    performSendMessage(content, apiContent)
    return
  }

  if (isAutosaveRef.value) {
    isAutosaveRef.value = false
    const xml = newVal.data?.trim()
    if (!xml) {
      console.warn('Draw.io autosave export is empty; keeping the previous session XML.')
      return
    }
    sessions.value = sessions.value.map(s => {
      if (s.id === currentSessionId.value) {
        return { ...s, drawIoXml: xml }
      }
      return s
    })
    return
  }

  imgData.value = newVal.data
}, { deep: true })

const handleKeyDown = (e: KeyboardEvent) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
    e.preventDefault()
    handleSendMessage()
  }
}

const getCurrentSessionDrawIoXml = () => {
  if (!currentSessionId.value) return ''
  return sessions.value.find(session => session.id === currentSessionId.value)?.drawIoXml?.trim() || ''
}

const buildMessageWithDrawIoContext = (message: string, exportedXml?: string) => {
  const xml = exportedXml?.trim() || getCurrentSessionDrawIoXml()
  if (!xml) {
    console.warn('Draw.io context is empty; sending the message without canvas context.')
    return message
  }

  return `[Context: Current Draw.io XML]\n\`\`\`xml\n${xml}\n\`\`\`\n\n${message}`
}

const handleAutoSave = (data: any) => {
  if (currentSessionId.value && isDrawIoReady.value && !isExportingForChatRef.value) {
    if (data && typeof data === 'object' && 'xml' in data) {
      const xmlContent = data.xml
      sessions.value = sessions.value.map(s => {
        if (s.id === currentSessionId.value) {
          return { ...s, drawIoXml: xmlContent }
        }
        return s
      })
    } else {
      isAutosaveRef.value = true
      exportDiagramXml(drawioRef.value)
    }
  }
}

const handleLoad = () => {
  isDrawIoReady.value = true
}

const handleExport = (data: any) => {
  const exportedData = (data.format as string) === 'xml' ? (data.xml || data.data) : data.data
  lastExportedData.value = { data: exportedData, timestamp: Date.now() }
}

const quickActions = [
  { label: '绘制 H5 登录流程图', text: '请帮我绘制一个 H5 端登录流程图，包含用户输入手机号、获取验证码、验证登录等步骤。' },
  { label: '绘制电商购物流程图', text: '请帮我绘制一个电商购物流程图，包含商品浏览、加入购物车、下单、支付、发货等环节。' }
]
</script>

<template>
  <div class="app-workbench bg-slate-50 text-slate-900 font-sans">
    <!-- Header -->
    <div class="h-14 px-6 bg-white border-b border-slate-200 flex items-center justify-between shrink-0 z-40 relative">
      <div class="flex items-center gap-3">
        <div class="bg-indigo-600 p-1.5 rounded-lg shadow-sm shadow-indigo-200">
          <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
            <circle cx="8.5" cy="8.5" r="1.5"></circle>
            <polyline points="21 15 16 10 5 21"></polyline>
          </svg>
        </div>
        <h1 class="text-lg font-bold text-slate-800 tracking-tight">ai + draw.io</h1>
      </div>

      <div class="flex items-center gap-3">
        <div class="flex items-center gap-2 px-3 py-1.5 bg-slate-50 rounded-full border border-slate-200 shadow-sm">
          <div class="w-2 h-2 rounded-full bg-green-500 shadow-[0_0_8px_rgba(34,197,94,0.4)]"></div>
          <span class="text-xs font-semibold text-slate-600">{{ currentUser || 'Guest' }}</span>
        </div>

        <div class="h-6 w-px bg-slate-200 mx-1"></div>

        <button
          @click="exportDiagram"
          class="flex items-center gap-2 px-4 py-1.5 bg-white border border-slate-200 text-slate-600 rounded-lg hover:bg-slate-50 hover:border-slate-300 hover:text-slate-900 transition-all text-sm font-medium shadow-sm active:scale-95"
        >
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
            <polyline points="7 10 12 15 17 10"></polyline>
            <line x1="12" y1="15" x2="12" y2="3"></line>
          </svg>
          Export
        </button>

        <button
          @click="handleLogout"
          class="p-2 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
          title="Logout"
        >
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path>
            <polyline points="16 17 21 12 16 7"></polyline>
            <line x1="21" y1="12" x2="9" y2="12"></line>
          </svg>
        </button>

        <button
          v-if="!isChatOpen"
          @click="isChatOpen = true"
          class="p-2 text-indigo-600 bg-indigo-50 hover:bg-indigo-100 rounded-lg transition-colors border border-indigo-100"
          title="Open Assistant"
        >
          <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>
          </svg>
        </button>
      </div>
    </div>

    <!-- Main Layout -->
    <div class="flex flex-1 min-h-0 w-full overflow-hidden relative">
      <!-- Sessions Sidebar -->
      <div class="w-64 min-h-0 bg-white text-slate-600 flex flex-col border-r border-slate-200 shrink-0 z-30">
        <div class="h-14 px-4 flex items-center justify-between border-b border-slate-100 shrink-0">
          <span class="font-semibold text-slate-800 flex items-center gap-2">
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-indigo-600">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>
            </svg>
            绘图记录
          </span>
          <button
            @click="handleNewChat"
            class="p-1.5 text-slate-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-md transition-all"
            title="New Chat"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <line x1="12" y1="5" x2="12" y2="19"></line>
              <line x1="5" y1="12" x2="19" y2="12"></line>
            </svg>
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-2 space-y-1 scrollbar-thin scrollbar-thumb-slate-200 scrollbar-track-transparent">
          <div
            v-for="session in [...sessions].sort((a, b) => b.lastModified - a.lastModified)"
            :key="session.id"
            @click="handleSwitchSession(session.id)"
            @dblclick.stop="handleDoubleClickSession(session)"
            :class="[
              'group flex items-center gap-3 px-3 py-3 rounded-lg cursor-pointer transition-all border border-transparent',
              currentSessionId === session.id
                ? 'bg-indigo-50 text-indigo-700 border-indigo-100 shadow-sm'
                : 'hover:bg-slate-50 text-slate-600 hover:text-slate-900'
            ]"
          >
            <div class="flex-1 min-w-0">
              <div :class="['text-sm font-medium truncate', currentSessionId === session.id ? 'text-indigo-700' : 'text-slate-700 group-hover:text-slate-900']">
                {{ session.title }}
              </div>
              <div :class="['text-[10px] mt-0.5', currentSessionId === session.id ? 'text-indigo-400' : 'text-slate-400']">
                {{ new Date(session.lastModified).toLocaleDateString() }} {{ new Date(session.lastModified).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}) }}
              </div>
            </div>
            <button
              @click.stop="handleDeleteSession($event, session.id)"
              :class="[
                'p-1.5 rounded-md transition-all opacity-0 group-hover:opacity-100',
                currentSessionId === session.id
                  ? 'hover:bg-indigo-100 text-indigo-400 hover:text-indigo-700'
                  : 'hover:bg-red-50 text-slate-400 hover:text-red-500'
              ]"
              title="Delete"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polyline points="3 6 5 6 21 6"></polyline>
                <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
              </svg>
            </button>
          </div>
          
          <!-- Empty State -->
          <div v-if="sessions.length === 0" class="flex flex-col items-center justify-center py-12 px-4 text-center">
            <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mb-3">
              <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-6 h-6 text-slate-300">
                <polygon points="12 2 2 7 12 12 22 7 12 2"></polygon>
                <polyline points="2 17 12 22 22 17"></polyline>
                <polyline points="2 12 12 17 22 12"></polyline>
              </svg>
            </div>
            <p class="text-sm font-medium text-slate-600">暂无绘图记录</p>
            <p class="text-xs text-slate-400 mt-1">在右侧与 AI 对话开始你的第一次创作吧</p>
          </div>
        </div>
      </div>

      <!-- Draw.io Canvas Area -->
      <div class="flex-1 min-h-0 relative bg-slate-50 h-full flex flex-col">
        <div class="drawio-canvas-shell flex-1 min-h-0 m-1.5 rounded-xl overflow-hidden border border-slate-200 bg-white ring-1 ring-slate-100 relative">
          <!-- Skeleton Loading Mask -->
          <div v-if="!isDrawIoReady" class="drawio-skeleton absolute inset-0 z-10 bg-slate-50 flex items-center justify-center overflow-hidden">
            <div class="relative z-10 flex w-[min(560px,86%)] flex-col items-center gap-4 rounded-2xl border border-slate-200 bg-white/85 p-8 text-center shadow-sm backdrop-blur-sm">
              <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-8 h-8 text-indigo-500 animate-spin">
                <path d="M21 12a9 9 0 1 1-6.219-8.56"></path>
              </svg>
              <span class="text-slate-500 text-sm font-medium">正在初始化画布...</span>
              <div class="mt-3 grid w-full grid-cols-3 gap-3">
                <div class="h-14 rounded-xl bg-slate-100"></div>
                <div class="h-14 rounded-xl bg-slate-100"></div>
                <div class="h-14 rounded-xl bg-slate-100"></div>
                <div class="col-span-3 h-2 rounded-full bg-slate-100"></div>
                <div class="col-span-2 h-2 rounded-full bg-slate-100"></div>
              </div>
            </div>
          </div>
          
          <DrawIoEmbed
            ref="drawioRef"
            :autosave="true"
            @autoSave="handleAutoSave"
            @load="handleLoad"
            @export="handleExport"
            :urlParameters="{
              ui: 'atlas',
              spin: true,
              libraries: true,
              saveAndExit: false,
              noSaveBtn: true,
              noExitBtn: true
            }"
          />
        </div>
      </div>

      <!-- Chat Sidebar -->
      <div
        :class="[
          'border-l border-slate-200/80 bg-white flex flex-col transition-all duration-300 ease-[cubic-bezier(0.25,0.1,0.25,1)]',
          isChatOpen ? 'w-full sm:w-[min(480px,44vw)] lg:w-[480px] translate-x-0' : 'w-0 translate-x-full opacity-0 overflow-hidden',
          'shadow-[0_0_36px_-24px_rgba(15,23,42,0.72)] z-20 min-h-0'
        ]"
      >
        <!-- Chat Header -->
        <div class="h-14 px-5 border-b border-slate-200/70 flex items-center justify-between shrink-0 bg-white/95 backdrop-blur-sm sticky top-0 z-10">
          <div class="flex items-center gap-3 flex-1 min-w-0">
            <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-indigo-600 text-white shadow-sm shadow-indigo-200 shrink-0 ring-1 ring-indigo-100">
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="m12 3-1.912 5.813a2 2 0 0 1-1.275 1.275L3 12l5.813 1.912a2 2 0 0 1 1.275 1.275L12 21l1.912-5.813a2 2 0 0 1 1.275-1.275L21 12l-5.813-1.912a2 2 0 0 1-1.275-1.275L12 3Z" />
              </svg>
            </div>
            <div class="flex-1 min-w-0">
              <select
                v-model="selectedAgentId"
                @change="handleAgentChange"
                class="w-full bg-transparent text-sm font-bold text-slate-800 focus:outline-none cursor-pointer truncate appearance-none pr-4"
                style="background-image: none;"
              >
                <option v-if="agents.length === 0" value="">Loading agents...</option>
                <option v-for="agent in agents" :key="agent.agentId" :value="agent.agentId">
                  {{ agent.agentName }}
                </option>
              </select>
              <div class="flex items-center gap-1.5 mt-0.5">
                <span class="w-1.5 h-1.5 rounded-full bg-green-500 animate-pulse"></span>
                <span class="text-[10px] text-slate-500 font-medium leading-tight">AI Assistant Online</span>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-1">
            <button
              @click="isChatOpen = false"
              class="p-1.5 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-md transition-all shrink-0"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <line x1="18" y1="6" x2="6" y2="18"></line>
                <line x1="6" y1="6" x2="18" y2="18"></line>
              </svg>
            </button>
          </div>
        </div>

        <!-- Messages Area -->
        <div class="flex-1 overflow-y-auto p-5 space-y-5 bg-slate-50 scrollbar-thin scrollbar-thumb-slate-200 scrollbar-track-transparent">
          <div
            v-for="(msg, index) in messages"
            :key="msg.id"
            :class="['flex gap-3', msg.role === 'user' ? 'flex-row-reverse' : 'flex-row']"
          >
            <div :class="[
              'shrink-0 w-8 h-8 rounded-lg flex items-center justify-center shadow-sm mt-1 ring-1 ring-white',
              msg.role === 'user' ? 'bg-slate-900 text-white' : 'bg-indigo-50 text-indigo-600 border border-indigo-100'
            ]">
              <svg v-if="msg.role === 'user'" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
                <circle cx="12" cy="7" r="4"></circle>
              </svg>
              <svg v-else xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M12 2a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2 2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z"></path>
                <path d="M4 11v6a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2z"></path>
                <path d="M9 22v-3"></path>
                <path d="M15 22v-3"></path>
              </svg>
            </div>

            <div :class="['flex flex-col min-w-0', msg.role === 'user' ? 'max-w-[78%]' : 'w-[calc(100%-2.75rem)] max-w-[calc(100%-2.75rem)]']">
              <span :class="['text-[10px] mb-1.5 font-medium', msg.role === 'user' ? 'text-right text-slate-400' : 'text-left text-slate-400']">
                {{ msg.role === 'user' ? 'You' : 'Agent' }}
              </span>
              <div :class="[
                'p-3.5 text-sm leading-relaxed whitespace-pre-wrap',
                msg.role === 'user'
                  ? 'bg-indigo-600 text-white rounded-xl rounded-tr-sm shadow-sm shadow-indigo-100'
                  : 'bg-white/95 border border-slate-200/80 text-slate-700 rounded-xl rounded-tl-sm shadow-[0_10px_28px_-24px_rgba(15,23,42,0.82)] markdown-body'
              ]">
                <template v-if="msg.role === 'user'">
                  {{ msg.content }}
                </template>
                <template v-else>
                  <div class="space-y-3">
                    <template v-for="(section, idx) in getSectionsForMessage(msg, isSending && index === messages.length - 1)" :key="`${section.statusText}-${idx}`">
                      <details v-if="section.kind === 'thinking' || section.kind === 'generation'" :open="(isSending && index === messages.length - 1) || !getSectionsForMessage(msg, isSending && index === messages.length - 1).some(s => s.kind === 'final' || s.kind === 'error')" class="group rounded-lg border border-slate-200/80 bg-slate-50/80 px-3 py-2">
                        <summary class="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-medium text-slate-700 transition-colors hover:text-slate-900 [&::-webkit-details-marker]:hidden">
                          <span class="flex min-w-0 items-center gap-2">
                            <svg
                              :class="[
                                'h-4 w-4 shrink-0 text-indigo-500',
                                isSending && index === messages.length - 1 ? 'thinking-orbit-icon' : ''
                              ]"
                              viewBox="0 0 24 24"
                              fill="none"
                              aria-hidden="true"
                            >
                              <path d="M7.5 7.5c3.9-3.9 9-5.1 11.4-2.7s1.2 7.5-2.7 11.4-9 5.1-11.4 2.7-1.2-7.5 2.7-11.4Z" stroke="currentColor" stroke-width="1.8" />
                              <path d="M16.5 7.5c3.9 3.9 5.1 9 2.7 11.4s-7.5 1.2-11.4-2.7-5.1-9-2.7-11.4 7.5-1.2 11.4 2.7Z" stroke="currentColor" stroke-width="1.8" />
                              <circle cx="12" cy="12" r="1.5" fill="currentColor" />
                            </svg>
                            <span class="truncate">
                              {{ getSectionsForMessage(msg, isSending && index === messages.length - 1).some(s => s.kind === 'final' || s.kind === 'error') ? '已思考' : ((isSending && index === messages.length - 1) ? '正在思考' : '已思考') }}
                            </span>
                          </span>
                          <svg class="h-4 w-4 shrink-0 text-slate-500 transition-transform group-open:rotate-180" viewBox="0 0 20 20" fill="none" aria-hidden="true">
                            <path d="M5 7.5L10 12.5L15 7.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
                          </svg>
                        </summary>
                        <div
                          ref="processContentRefs"
                          :data-active-process="isSending && index === messages.length - 1 ? 'true' : undefined"
                          role="log"
                          aria-label="思考过程"
                          aria-live="polite"
                           class="mt-2 max-h-[42vh] min-h-0 overflow-y-auto rounded-md border border-slate-200/70 bg-white/80 p-3 whitespace-pre-wrap break-words text-xs leading-relaxed text-slate-500 scrollbar-thin scrollbar-thumb-slate-300 scrollbar-track-transparent"
                        >
                          {{ section.content }}
                        </div>
                      </details>
                      <div v-else :class="[idx > 0 ? 'border-t border-slate-100 pt-3' : '', section.kind === 'error' ? 'rounded-lg border border-rose-200 bg-rose-50 p-3' : '']">
                        <div :class="['mb-2 flex items-center gap-2 text-sm font-semibold', section.kind === 'error' ? 'text-rose-700' : 'text-slate-900']">
                          <span>{{ section.kind === 'error' ? '请求异常' : '回答结果' }}</span>
                        </div>
                        <div
                          :class="['whitespace-normal break-words leading-relaxed', section.kind === 'error' ? 'text-rose-700' : 'text-slate-950']"
                          @click="handleMarkdownClick"
                          v-html="renderMarkdown(section.content)"
                        >
                        </div>
                      </div>
                    </template>
                  </div>
                </template>
              </div>
            </div>
          </div>
          <div ref="messagesEndRef"></div>
        </div>

        <!-- Input Area -->
        <div class="p-4 bg-white/95 border-t border-slate-200/70 shrink-0 relative z-20 shadow-[0_-12px_28px_-28px_rgba(15,23,42,0.55)]">
          <div v-if="messages.length <= 1" class="flex flex-wrap gap-2 mb-3 px-1 animate-in fade-in slide-in-from-bottom-2 duration-300">
            <button
              v-for="(action, idx) in quickActions"
              :key="idx"
              @click="inputValue = action.text"
              class="text-xs px-3 py-1.5 bg-white text-slate-600 rounded-lg hover:bg-indigo-50 hover:text-indigo-700 transition-colors border border-slate-200 hover:border-indigo-200 font-medium"
            >
              {{ action.label }}
            </button>
          </div>

          <div class="flex items-center gap-2 mb-2 px-1">
            <button
              @click="useHistoryContext = !useHistoryContext"
              :class="[
                'flex items-center gap-2 px-2.5 py-1.5 rounded-lg text-xs font-medium transition-all border',
                useHistoryContext ? 'bg-indigo-50 text-indigo-700 border-indigo-200' : 'bg-white text-slate-500 border-slate-200 hover:bg-slate-50 hover:text-slate-700'
              ]"
            >
              <span :class="[
                'relative inline-flex h-4 w-7 shrink-0 items-center rounded-full transition-colors',
                useHistoryContext ? 'bg-indigo-600' : 'bg-slate-300'
              ]">
                <span :class="[
                  'inline-block h-3 w-3 rounded-full bg-white shadow-sm transition-transform',
                  useHistoryContext ? 'translate-x-3.5' : 'translate-x-0.5'
                ]"></span>
              </span>
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" :class="['w-3.5 h-3.5', useHistoryContext ? 'text-indigo-600' : 'text-slate-400']">
                <polygon points="12 2 2 7 12 12 22 7 12 2"></polygon>
                <polyline points="2 17 12 22 22 17"></polyline>
                <polyline points="2 12 12 17 22 12"></polyline>
              </svg>
              <span>携带画布上下文</span>
            </button>
            <div class="flex items-center rounded-lg border border-slate-200 bg-slate-100 p-0.5">
              <button
                v-for="option in [{ value: 'normal', label: '普通' }, { value: 'stream', label: '流式' }]"
                :key="option.value"
                type="button"
                @click="chatMode = option.value as ChatMode"
                :disabled="isSending"
                :class="[
                  'px-2.5 py-1 rounded-md text-xs font-medium transition-all',
                  chatMode === option.value ? 'bg-white text-slate-900 shadow-sm' : 'text-slate-500 hover:text-slate-700',
                  isSending ? 'cursor-not-allowed opacity-70' : ''
                ]"
              >
                {{ option.label }}
              </button>
            </div>
            <span class="text-[10px] text-slate-400 ml-auto hidden sm:inline-block">
              Press <kbd class="font-sans px-1 py-0.5 bg-slate-100 border border-slate-200 rounded text-slate-500">Ctrl/Command</kbd> + <kbd class="font-sans px-1 py-0.5 bg-slate-100 border border-slate-200 rounded text-slate-500">Enter</kbd>
            </span>
          </div>
          <div class="relative flex items-end gap-2 bg-slate-50 p-1.5 rounded-xl border border-slate-200 focus-within:border-indigo-300 focus-within:ring-4 focus-within:ring-indigo-50/50 focus-within:bg-white transition-all">
            <textarea
              v-model="inputValue"
              @keydown="handleKeyDown"
              :placeholder="isSending ? 'AI 正在思考中...' : '输入你的问题，描述你的绘图需求...'"
              :disabled="isSending"
              class="flex-1 px-3 py-2 bg-transparent border-none focus:ring-0 text-sm text-slate-800 placeholder:text-slate-400 resize-none max-h-60 min-h-[50px] scrollbar-thin scrollbar-thumb-slate-200 scrollbar-track-transparent"
              rows="1"
              style="height: auto; min-height: 50px;"
            ></textarea>
            <div class="flex gap-1 mb-0.5 shrink-0">
              <button
                @click="handleSendMessage"
                :disabled="!inputValue.trim() || isSending"
                :class="[
                  'p-2.5 rounded-lg transition-all duration-200 flex items-center justify-center',
                  inputValue.trim() && !isSending ? 'bg-indigo-600 text-white shadow-sm shadow-indigo-200 hover:bg-indigo-700 active:scale-95' : 'bg-slate-200 text-slate-400 cursor-not-allowed'
                ]"
              >
                <svg v-if="isSending" xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="animate-spin w-4 h-4">
                  <path d="M21 12a9 9 0 1 1-6.219-8.56"></path>
                </svg>
                <svg v-else xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-4 h-4">
                  <line x1="22" y1="2" x2="11" y2="13"></line>
                  <polygon points="22 2 15 22 11 13 2 9 22 2"></polygon>
                </svg>
              </button>
              <button
                @click="handleRestartSession"
                class="p-2.5 rounded-lg bg-white text-slate-400 hover:bg-slate-50 hover:text-indigo-600 transition-all duration-200 border border-slate-200 hover:border-indigo-200"
                title="Restart Session"
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-4 h-4">
                  <line x1="12" y1="5" x2="12" y2="19"></line>
                  <line x1="5" y1="12" x2="19" y2="12"></line>
                </svg>
              </button>
            </div>
          </div>
          <div class="text-center mt-2.5">
            <p class="text-[10px] text-slate-400 font-medium">
              {{ isSending ? (chatMode === 'normal' ? '普通模式正在生成完整回复，请稍候...' : '流式模式正在持续接收回复...') : 'AI can make mistakes. Please verify important info.' }}
            </p>
          </div>
        </div>
      </div>
    </div>

    <!-- Export Modal -->
    <div v-if="imgData" class="absolute inset-0 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center z-50 p-6 animate-in fade-in duration-200">
      <div class="bg-white p-0 rounded-2xl shadow-2xl max-h-[90vh] flex flex-col w-full max-w-4xl overflow-hidden animate-in zoom-in-95 duration-200 border border-white/20">
        <div class="flex justify-between items-center px-6 py-4 border-b border-slate-100 bg-slate-50/50">
          <div class="flex items-center gap-3">
            <div class="p-2 bg-green-100 text-green-600 rounded-lg">
              <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-5 h-5">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                <polyline points="7 10 12 15 17 10"></polyline>
                <line x1="12" y1="15" x2="12" y2="3"></line>
              </svg>
            </div>
            <div>
              <h2 class="text-lg font-bold text-slate-800">Export Ready</h2>
              <p class="text-xs text-slate-500">Your diagram has been successfully converted</p>
            </div>
          </div>
          <button
            @click="imgData = null"
            class="p-2 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-full transition-colors"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-5 h-5">
              <line x1="18" y1="6" x2="6" y2="18"></line>
              <line x1="6" y1="6" x2="18" y2="18"></line>
            </svg>
          </button>
        </div>

        <div class="flex-1 overflow-auto bg-slate-50/50 p-8 flex items-center justify-center min-h-[400px]">
          <div class="bg-white p-2 rounded shadow-sm border border-slate-200">
            <img :src="imgData" alt="Exported diagram" class="max-w-full h-auto object-contain" />
          </div>
        </div>

        <div class="px-6 py-4 border-t border-slate-100 bg-white flex justify-end gap-3">
          <button
            @click="imgData = null"
            class="px-5 py-2.5 text-slate-600 font-medium hover:bg-slate-100 rounded-lg transition-colors text-sm"
          >
            Close Preview
          </button>
          <a
            :href="imgData"
            download="diagram.svg"
            class="px-5 py-2.5 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 shadow-lg shadow-indigo-200 hover:shadow-indigo-300 transition-all text-sm flex items-center gap-2"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-4 h-4">
              <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
              <polyline points="7 10 12 15 17 10"></polyline>
              <line x1="12" y1="15" x2="12" y2="3"></line>
            </svg>
            Download File
          </a>
        </div>
      </div>
    </div>

    <!-- Rename Modal -->
    <div v-if="isRenameModalOpen" class="absolute inset-0 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center z-50 p-6 animate-in fade-in duration-200">
      <div class="bg-white rounded-2xl shadow-2xl w-full max-w-md overflow-hidden animate-in zoom-in-95 duration-200 border border-white/20">
        <div class="px-6 py-4 border-b border-slate-100 bg-slate-50/50 flex justify-between items-center">
          <h2 class="text-lg font-bold text-slate-800">Rename Session</h2>
          <button
            @click="isRenameModalOpen = false"
            class="p-1 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-full transition-colors"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-5 h-5">
              <line x1="18" y1="6" x2="6" y2="18"></line>
              <line x1="6" y1="6" x2="18" y2="18"></line>
            </svg>
          </button>
        </div>

        <div class="p-6">
          <label class="block text-sm font-medium text-slate-700 mb-2">
            Session Name
          </label>
          <input
            type="text"
            v-model="newSessionTitle"
            @keydown.enter="handleRenameSave"
            class="w-full px-4 py-2 border border-slate-300 rounded-lg focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 outline-none transition-all"
            placeholder="Enter new name"
            autofocus
          />
        </div>

        <div class="px-6 py-4 border-t border-slate-100 bg-slate-50/50 flex justify-end gap-3">
          <button
            @click="isRenameModalOpen = false"
            class="px-4 py-2 text-slate-600 font-medium hover:bg-slate-100 rounded-lg transition-colors text-sm"
          >
            Cancel
          </button>
          <button
            @click="handleRenameSave"
            class="px-4 py-2 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 shadow-lg shadow-indigo-200 hover:shadow-indigo-300 transition-all text-sm"
          >
            Save Changes
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Scoped styles if necessary */
</style>
