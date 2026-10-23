(() => {
  const focused = document.activeElement;
  if (focused?.type === 'password') return JSON.stringify({secure:true});
  const path = node => {
    const result = [];
    for (let depth=0;node?.parentNode && depth<64;depth++,node=node.parentNode) {
      result.unshift(Array.prototype.indexOf.call(node.parentNode.childNodes,node));
    }
    return result;
  };
  let text='',html='',identity=[],editable=false;
  if (focused && ['TEXTAREA','INPUT'].includes(focused.tagName)
      && typeof focused.selectionStart === 'number') {
    const start=focused.selectionStart,end=focused.selectionEnd,value=String(focused.value??'');
    if(value.length>2097152) return JSON.stringify({secure:true});
    text=value.slice(start,end);
    editable=!focused.readOnly&&!focused.disabled;
    identity=[path(focused),start,end,value];
  } else {
    const selected=window.getSelection();
    if(selected?.rangeCount) {
      const range=selected.getRangeAt(0);
      text=selected.toString();
      const wrapper=document.createElement('div');
      wrapper.appendChild(range.cloneContents());
      html=wrapper.innerHTML;
      const owner=range.commonAncestorContainer.nodeType===1?range.commonAncestorContainer:range.commonAncestorContainer.parentElement;
      editable=!!owner?.isContentEditable;
      identity=[path(range.startContainer),range.startOffset,path(range.endContainer),range.endOffset,
        editable?String(owner.textContent??'').slice(0,2097152):''];
    }
  }
  return JSON.stringify({text,html,editable,identity:JSON.stringify(identity),url:location.href,title:document.title});
})();
