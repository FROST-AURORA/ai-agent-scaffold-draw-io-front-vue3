export const API_CONFIG = {
  // Use environment variable from window.__ENV (runtime) or import.meta.env (build/server)
  BASE_URL: (typeof window !== 'undefined' && window.__ENV?.NEXT_PUBLIC_API_BASE_URL) 
    ? window.__ENV.NEXT_PUBLIC_API_BASE_URL 
    : (import.meta.env.VITE_API_BASE_URL || 'http://localhost:8093/api/v1'),
};
