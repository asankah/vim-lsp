" constants {{{

let s:kind_text_mappings = {
            \ '1': 'text',
            \ '2': 'method',
            \ '3': 'function',
            \ '4': 'constructor',
            \ '5': 'field',
            \ '6': 'variable',
            \ '7': 'class',
            \ '8': 'interface',
            \ '9': 'module',
            \ '10': 'property',
            \ '11': 'unit',
            \ '12': 'value',
            \ '13': 'enum',
            \ '14': 'keyword',
            \ '15': 'snippet',
            \ '16': 'color',
            \ '17': 'file',
            \ '18': 'reference',
            \ }

let s:kind_type_mappings = {
            \ '1': '-',
            \ '2': 'f',
            \ '3': 'f',
            \ '4': 'f',
            \ '5': 'm',
            \ '6': 'v',
            \ '7': 't',
            \ '8': 't',
            \ '9': 't',
            \ '10': 'm',
            \ '11': '-',
            \ '12': 'c',
            \ '13': 'c',
            \ '14': 'k',
            \ '15': '-',
            \ '16': '-',
            \ '17': 'F',
            \ '18': 'r',
            \ }

let s:completion_status_success = 'success'
let s:completion_status_failed = 'failed'
let s:completion_status_pending = 'pending'

" }}}

" completion state
let s:completion = {'counter': 0, 'status': '', 'matches': []}

function! lsp#omni#complete(findstart, base) abort
    let l:info = s:find_complete_servers_and_start_pos()
    if empty(l:info['server_names'])
        return a:findstart ? -1 : []
    endif

    if a:findstart
        if g:lsp_async_completion
            return col('.')
        else
            return l:info['findstart'] - 1
        endif
    else
        if !g:lsp_async_completion
            let s:completion['status'] = s:completion_status_pending
        endif

        call s:send_completion_request(l:info)

        if g:lsp_async_completion
            return []
        else
            while s:completion['status'] is# s:completion_status_pending && !complete_check()
                sleep 10m
            endwhile
            let s:completion['matches'] = filter(s:completion['matches'], {_, match -> match['word'] =~ '^' . a:base})
            let s:completion['status'] = ''
            return s:completion['matches']
        endif
    endif
endfunction

function! s:handle_omnicompletion(server_name, startcol, complete_counter, data) abort
    if s:completion['counter'] != a:complete_counter
        " ignore old completion results
        return
    endif

    if lsp#client#is_error(a:data) || !has_key(a:data, 'response') || !has_key(a:data['response'], 'result')
        let s:completion['status'] = s:completion_status_failed
        return
    endif

    let l:result = s:get_completion_result(a:data)
    let l:matches = l:result['matches']

    if g:lsp_async_completion
        call complete(a:startcol, l:matches)
    else
        let s:completion['matches'] = l:matches
        let s:completion['status'] = s:completion_status_success
    endif
endfunction

function! lsp#omni#get_kind_text(completion_item) abort
    return has_key(a:completion_item, 'kind') && has_key(s:kind_text_mappings, a:completion_item['kind']) ? s:kind_text_mappings[a:completion_item['kind']] : ''
endfunction

function! lsp#omni#get_kind_type(completion_item) abort
    return has_key(a:completion_item, 'kind') && has_key(s:kind_type_mappings, a:completion_item['kind']) ? s:kind_type_mappings[a:completion_item['kind']] : ''
endfunction

" auxiliary functions {{{

function! s:find_complete_servers_and_start_pos() abort
    let l:server_names = []
    for l:server_name in lsp#get_whitelisted_servers()
        let l:init_capabilities = lsp#get_server_capabilities(l:server_name)
        if has_key(l:init_capabilities, 'completionProvider')
            " TODO: support triggerCharacters
            call add(l:server_names, l:server_name)
        endif
    endfor

    let l:typed = strpart(getline('.'), 0, col('.') - 1)
    " TODO: allow user to customize refresh patterns
    let l:refresh_pattern = '\k\+$'
    let l:matchpos = lsp#utils#matchstrpos(l:typed, l:refresh_pattern)
    let l:startpos = l:matchpos[1]
    let l:endpos = l:matchpos[2]
    let l:typed_len = l:endpos - l:startpos
    let l:findstart = len(l:typed) - l:typed_len + 1

    return { 'findstart': l:findstart, 'server_names': l:server_names }
endfunction

function! s:send_completion_request(info) abort
    let s:completion['counter'] = s:completion['counter'] + 1
    let l:server_name = a:info['server_names'][0]
    " TODO: support multiple servers
    call lsp#send_request(l:server_name, {
                \ 'method': 'textDocument/completion',
                \ 'params': {
                \   'textDocument': lsp#get_text_document_identifier(),
                \   'position': lsp#get_position(),
                \ },
                \ 'on_notification': function('s:handle_omnicompletion', [l:server_name, a:info['findstart'], s:completion['counter']]),
                \ })
endfunction

function! s:get_completion_result(data) abort
    let l:result = a:data['response']['result']

    if type(l:result) == type([])
        let l:items = l:result
        let l:incomplete = 0
    else
        let l:items = l:result['items']
        let l:incomplete = l:result['isIncomplete']
    endif

    let l:matches = map(l:items, {_, item -> lsp#omni#get_vim_completion_item(item) })

    return {'matches': l:matches, 'incomplete': l:incomplete}
endfunction

function! lsp#omni#crack_snippet(text)
  let l:idx = stridx(a:text, '${')
  if l:idx >= 1
    return [a:text[0 : l:idx - 1], a:text]
  endif
  return [a:text, '']
endfunction

function! lsp#omni#get_abbr_for_snippet(text, item)
  if !has_key(a:item, 'insertTextFormat') || a:item['insertTextFormat'] != 2
    return [a:text,  a:item['label'], '']
  endif

  let [l:plain, l:snippet] = lsp#omni#crack_snippet(a:text)
  return [l:plain,
        \ a:item['label'],
        \ json_encode({'snippet': l:snippet, 'snippet_trigger': l:plain})]
endfunction

function! lsp#omni#get_vim_completion_item(item) abort
    if has_key(a:item, 'textEdit') && has_key(a:item['textEdit'], 'newText')
        let [l:word, l:abbr, l:snippet] = lsp#omni#get_abbr_for_snippet(a:item['textEdit']['newText'], a:item)
    elseif has_key(a:item, 'insertText') && !empty(a:item['insertText'])
        let [l:word, l:abbr, l:snippet] = lsp#omni#get_abbr_for_snippet(a:item['insertText'], a:item)
    else
        let l:word = a:item['label']
        let l:abbr = a:item['label']
        let l:snippet = ''
    endif
    if has_key(a:item, 'detail')
      let l:menu = a:item['detail']
    else
      let l:menu = lsp#omni#get_kind_text(a:item)
    endif
    let l:kind = lsp#omni#get_kind_type(a:item)
    let l:completion = {
          \  'word': l:word,
          \  'abbr': l:abbr,
          \  'menu': l:menu,
          \  'icase': 1,
          \  'dup': 1,
          \  'kind': l:kind,
          \  'user_data': l:snippet }
    if has_key(a:item, 'documentation')
        if type(a:item['documentation']) == type('')
            let l:completion['info'] = a:item['documentation']
        endif
    endif
    return l:completion
endfunction

function! lsp#omni#complete_done()
  if exists('g:loaded_neosnippet')
    call neosnippet#complete_done()
    return
  endif

  if exists('did_plugin_ultisnips')
    if !has_key(v:completed_item, 'user_data')
      return
    endif
    let l:snip = json_decode(v:completed_item['user_data'])
    if !has_key(l:snip, 'snippet') || !has_key(l:snip, 'snippet_trigger')
      return
    endif

    call UltiSnips#Anon(l:snip['snippet'], l:snip['snippet_trigger'], '', 'i')
  endif
endfunction

" }}}
