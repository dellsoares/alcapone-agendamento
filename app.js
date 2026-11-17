/* Al Capone Barbearia | Agendamento estático + Supabase (projeto separado da landing) */
(() => {
  'use strict';
  const URL_BASE = 'https://vsqvzfwlndkwmajkvtuc.supabase.co';
  const PUBLIC_KEY = 'sb_publishable_SwpbISATzFXp2N8T6IRPIA_V6k6Xecg';
  const $ = (s, root=document) => root.querySelector(s);
  const $$ = (s, root=document) => [...root.querySelectorAll(s)];
  const esc = s => String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const brl = cents => (cents/100).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
  const todayBR = () => new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  const addDays = (iso, days) => {const d=new Date(iso+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10)};
  const weekday = iso => new Date(iso+'T12:00:00Z').toLocaleDateString('pt-BR',{weekday:'short',timeZone:'UTC'}).replace('.','').toUpperCase();
  const formattedDate = iso => new Date(iso+'T12:00:00Z').toLocaleDateString('pt-BR',{timeZone:'UTC',day:'2-digit',month:'long',year:'numeric'});
  async function rpc(name, body={}){
    const response=await fetch(`${URL_BASE}/rest/v1/rpc/${name}`,{
      method:'POST', headers:{'Content-Type':'application/json','Accept':'application/json','apikey':PUBLIC_KEY},
      body:JSON.stringify(body), cache:'no-store'
    });
    let payload;
    try {payload=await response.json();}catch{payload=null;}
    if(!response.ok)throw Error(payload?.message || payload?.hint || `Erro de conexão (${response.status}).`);
    return payload;
  }
  let data=null,step=1,dateOffset=0,fetching=0;
  const booking={service_id:null, professional_id:null, date:null, time:null, coupon:null};
  const state=()=>({service:data.services.find(x=>x.id===booking.service_id),pro:data.professionals.find(x=>x.id===booking.professional_id)});
  $('#currentYear').textContent=new Date().getFullYear();
  async function init(){
    $('#serviceOptions').innerHTML='<p class="empty-note">Carregando serviços...</p>';
    try{
      data=await rpc('alcapone_catalogo');
      if(!data?.services?.length||!data?.professionals?.length)throw Error('O catálogo ainda não está configurado.');
      booking.date=data.today || todayBR();
      $('#demoBanner').hidden=true;
      renderServices();renderPros();renderDates();go(1);
    }catch(e){
      $('#demoBanner').hidden=false;
      $('#serviceOptions').innerHTML=`<p class="empty-note">Não foi possível carregar os serviços. ${esc(e.message)}</p><button type="button" class="action-secondary" id="retryInit">TENTAR NOVAMENTE ↻</button>`;
      $('#retryInit').addEventListener('click',init);
    }
  }
  function renderServices(){
    $('#serviceOptions').innerHTML=data.services.map(s=>{
      const featured=/visagis/i.test(s.name);
      return `<button type="button" class="choice ${featured?'is-visagista':''}" data-id="${esc(s.id)}" aria-pressed="false">
        <div>${featured?'<span class="choice-tag">✦ ATENDIMENTO DESTAQUE</span>':''}<strong>${esc(s.name)}</strong></div>
        <span class="choice-foot"><small>${s.duration} MIN</small><b>${s.from_price?'A partir de ':''}${brl(s.price_cents)}</b></span></button>`;
    }).join('');
    $$('.choice').forEach(btn=>btn.addEventListener('click',()=>{
      booking.service_id=btn.dataset.id; booking.time=null; booking.coupon=null;
      $('#clientCouponCode').value='';setCouponMessage('');
      $$('.choice').forEach(el=>{el.classList.toggle('selected',el===btn);el.setAttribute('aria-pressed',String(el===btn))});updateNext();
    }));
  }
  function renderPros(){
    $('#proOptions').innerHTML=data.professionals.map(p=>`<button type="button" class="pro-choice" data-id="${esc(p.id)}" aria-pressed="false"><img src="${esc(p.photo)}" alt="${esc(p.name)}, profissional da Al Capone"><span><small>BARBEIRO AL CAPONE</small><strong>${esc(p.name)}</strong></span></button>`).join('');
    $$('.pro-choice').forEach(btn=>btn.addEventListener('click',()=>{
      booking.professional_id=btn.dataset.id;booking.time=null;
      $$('.pro-choice').forEach(el=>{el.classList.toggle('selected',el===btn);el.setAttribute('aria-pressed',String(el===btn))});updateNext();
    }));
  }
  function go(n){
    step=n;
    $$('.wizard-panel').forEach(el=>el.classList.toggle('active',Number(el.dataset.panel)===n));
    $$('.steps li').forEach(el=>{const s=Number(el.dataset.step);el.classList.toggle('active',s===Math.min(n,4));el.classList.toggle('done',s<Math.min(n,4))});
    $('#wizardFooter').hidden=n===5;
    $('#backBtn').hidden=n<=1;
    if(n===3){renderDates();loadAvailability();}
    if(n===4)renderSummary();
    updateNext();
    if(n===5)$('#formulario').scrollIntoView({block:'start',behavior:'smooth'});
  }
  function updateNext(){
    const btn=$('#nextBtn');btn.textContent=step===4?'CONFIRMAR RESERVA':'CONTINUAR';
    if(step!==4)btn.insertAdjacentHTML('beforeend',' <span>↗</span>');
    btn.disabled=(step===1&&!booking.service_id)||(step===2&&!booking.professional_id)||(step===3&&!booking.time);
    $('#stepHint').textContent=({1:'Escolha um serviço.',2:'Selecione o profissional.',3:'Selecione uma data e um horário.',4:'Seus dados serão usados somente para esta reserva.'})[step]||'';
  }
  $('#nextBtn').addEventListener('click',()=>{if(step===4){submit();return;}if(!$('#nextBtn').disabled)go(step+1)});
  $('#backBtn').addEventListener('click',()=>go(Math.max(1,step-1)));
  $('#newBooking').addEventListener('click',()=>{booking.service_id=null;booking.professional_id=null;booking.time=null;booking.coupon=null;$('#clientCouponCode').value='';setCouponMessage('');renderServices();renderPros();go(1)});
  function renderDates(){
    if(!data)return;
    const current=addDays(data.today,dateOffset),last=addDays(data.today,data.max_days);
    $('#monthTitle').textContent=new Date(current+'T12:00:00Z').toLocaleDateString('pt-BR',{month:'long',year:'numeric',timeZone:'UTC'}).toUpperCase();
    $('#datePrev').disabled=dateOffset===0;
    $('#dateNext').disabled=dateOffset+7>data.max_days;
    let html='';
    for(let i=0;i<7;i++){
      const iso=addDays(current,i),wd=new Date(iso+'T12:00:00Z').getUTCDay();
      const closed=wd===0||wd===1,out=iso>last;
      html+=`<button type="button" class="day-pill ${booking.date===iso?'selected':''}" data-date="${iso}" ${closed||out?'disabled':''} aria-pressed="${booking.date===iso}"><small>${weekday(iso)}</small><strong>${iso.slice(8)}</strong></button>`;
    }
    $('#daysStrip').innerHTML=html;
    $$('.day-pill:not(:disabled)').forEach(el=>el.addEventListener('click',()=>{booking.date=el.dataset.date;booking.time=null;renderDates();loadAvailability();updateNext()}));
  }
  $('#dateNext').addEventListener('click',()=>{dateOffset=Math.min(dateOffset+7,56);booking.date=null;booking.time=null;renderDates();$('#slotArea').innerHTML='<p class="empty-note">Selecione uma data para consultar os horários.</p>';updateNext()});
  $('#datePrev').addEventListener('click',()=>{dateOffset=Math.max(0,dateOffset-7);booking.date=null;booking.time=null;renderDates();$('#slotArea').innerHTML='<p class="empty-note">Selecione uma data para consultar os horários.</p>';updateNext()});
  async function loadAvailability(){
    const seq=++fetching;if(!booking.date)return;
    $('#slotArea').innerHTML='<p class="empty-note">Consultando horários...</p>';
    $('#availabilityMeta').textContent=formattedDate(booking.date);
    try{
      const result=await rpc('alcapone_disponibilidade',{p_profissional_id:booking.professional_id,p_servico_id:booking.service_id,p_data:booking.date});
      const slots=(result||[]).map(item=>item.hora);
      if(seq!==fetching)return;
      if(!slots.length){$('#slotArea').innerHTML='<p class="empty-note">Sem horários disponíveis. Experimente outra data.</p>';booking.time=null;updateNext();return;}
      let html='';
      for(const [title,items] of [['MANHÃ',slots.filter(s=>s<'12:00')],['TARDE',slots.filter(s=>s>='12:00')]]){
        if(!items.length)continue;
        html+=`<div class="period-label">${title}</div><div class="time-buttons">${items.map(s=>`<button type="button" class="time-slot ${booking.time===s?'selected':''}" data-time="${esc(s)}" aria-pressed="${booking.time===s}">${esc(s)}</button>`).join('')}</div>`;
      }
      $('#slotArea').innerHTML=html;
      $$('.time-slot').forEach(el=>el.addEventListener('click',()=>{booking.time=el.dataset.time;$$('.time-slot').forEach(e=>{e.classList.toggle('selected',e===el);e.setAttribute('aria-pressed',String(e===el))});updateNext()}));
    }catch(e){if(seq===fetching)$('#slotArea').innerHTML=`<p class="empty-note">${esc(e.message)}. Tente outra data ou recarregue a página.</p>`;}
  }
  function setCouponMessage(text,type=''){
    const el=$('#couponMessage');if(!el)return;
    el.textContent=text||'';el.classList.toggle('success',type==='success');el.classList.toggle('error',type==='error');
  }
  function clearAppliedCoupon(message=''){
    if(!booking.coupon)return;
    booking.coupon=null;setCouponMessage(message,'');
    if(step===4)renderSummary();
  }
  $('#applyCoupon').addEventListener('click',async()=>{
    const code=$('#clientCouponCode').value.trim().toUpperCase();
    const phone=$('#clientPhone').value.trim();
    const phoneDigits=phone.replace(/\D/g,'');
    const serviceId=booking.service_id;
    if(!code){setCouponMessage('Digite o código do cupom.','error');return;}
    if(phoneDigits.length<10){setCouponMessage('Informe primeiro seu WhatsApp com DDD.','error');$('#clientPhone').focus();return;}
    const button=$('#applyCoupon');button.disabled=true;button.textContent='VALIDANDO...';$('#nextBtn').disabled=true;setCouponMessage('Consultando campanha...');
    try{
      const result=await rpc('alcapone_validar_cupom',{p_codigo:code,p_servico_id:serviceId,p_whatsapp:phone});
      if(!result?.valid)throw new Error(result?.message||'Não foi possível aplicar este cupom.');
      if($('#clientCouponCode').value.trim().toUpperCase()!==code||$('#clientPhone').value.replace(/\D/g,'')!==phoneDigits||booking.service_id!==serviceId)throw new Error('Os dados foram alterados durante a validação. Aplique o cupom novamente.');
      booking.coupon={...result,code:result.code||code,service_id:serviceId,phone:phoneDigits};
      setCouponMessage(`Cupom ${booking.coupon.code} aplicado. Desconto de ${brl(Math.round(Number(result.discount_amount)*100))}.`,'success');
      renderSummary();
    }catch(e){booking.coupon=null;setCouponMessage(e.message,'error');renderSummary();}
    finally{button.disabled=false;button.textContent='APLICAR';updateNext();}
  });
  $('#clientCouponCode').addEventListener('input',()=>{
    if(booking.coupon&&$('#clientCouponCode').value.trim().toUpperCase()!==booking.coupon.code)clearAppliedCoupon('Código alterado. Aplique novamente para validar.');
  });
  $('#clientPhone').addEventListener('input',()=>{
    if(booking.coupon&&$('#clientPhone').value.replace(/\D/g,'')!==booking.coupon.phone)clearAppliedCoupon('WhatsApp alterado. Aplique o cupom novamente.');
  });
  function renderSummary(){
    const {service,pro}=state();
    const discountCents=booking.coupon?Math.round(Number(booking.coupon.discount_amount)*100):0;
    const totalCents=Math.max(0,service.price_cents-discountCents);
    const couponRows=booking.coupon?`<div class="summary-row"><span>VALOR ORIGINAL</span><strong>${brl(service.price_cents)}</strong></div><div class="summary-row"><span>CUPOM</span><strong>${esc(booking.coupon.code)}</strong></div><div class="summary-row"><span>DESCONTO</span><strong>− ${brl(discountCents)}</strong></div>`:'';
    const totalLabel=booking.coupon?'VALOR FINAL':`VALOR ${service.from_price?'INICIAL':'DO SERVIÇO'}`;
    $('#summary').innerHTML=`<div class="summary-row"><span>SERVIÇO</span><strong>${esc(service.name)}</strong></div><div class="summary-row"><span>PROFISSIONAL</span><strong>${esc(pro.name)}</strong></div><div class="summary-row"><span>DATA E HORA</span><strong>${esc(formattedDate(booking.date))} · ${esc(booking.time)}</strong></div><div class="summary-row"><span>DURAÇÃO</span><strong>${service.duration} minutos</strong></div>${couponRows}<div class="summary-row summary-total"><span>${totalLabel}</span><strong>${brl(totalCents)}</strong></div>`;
    $('#formError').hidden=true;
  }
  function calendarDateParts(date, time, duration){
    const start = new Date(`${date}T${time}:00-03:00`);
    const end = new Date(start.getTime() + Number(duration || 30) * 60000);
    const googleStamp = d => new Intl.DateTimeFormat('sv-SE',{
      timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit',
      hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'
    }).format(d).replace(/[-:]/g,'').replace(' ','T');
    const utcStamp = d => d.toISOString().replace(/[-:]/g,'').replace(/\.\d{3}Z$/,'Z');
    return {start,end,googleStart:googleStamp(start),googleEnd:googleStamp(end),utcStart:utcStamp(start),utcEnd:utcStamp(end)};
  }
  function icsEscape(value){
    return String(value ?? '').replace(/\\/g,'\\\\').replace(/\r?\n/g,'\\n').replace(/,/g,'\\,').replace(/;/g,'\\;');
  }
  function prepareConfirmationActions({payload,service,professional,clientName,phone}){
    const {start,end,googleStart,googleEnd,utcStart,utcEnd}=calendarDateParts(booking.date,booking.time,service.duration);
    const title=`Al Capone Barbearia — ${service.name}`;
    const location='Rua Padre Eustáquio, 2160, Belo Horizonte/MG';
    const code=payload.code || '';
    const details=`Reserva ${code}\nCliente: ${clientName}\nServiço: ${service.name}\nProfissional: ${professional.name}\nDuração: ${service.duration} minutos\nCódigo: ${code}\nConsulte ou cancele: ${new URL(`minha.html?token=${encodeURIComponent(payload.token)}`,locationHref()).href}`;
    const googleUrl='https://calendar.google.com/calendar/render?action=TEMPLATE'
      +`&text=${encodeURIComponent(title)}`
      +`&dates=${googleStart}/${googleEnd}`
      +`&ctz=${encodeURIComponent('America/Sao_Paulo')}`
      +`&details=${encodeURIComponent(details)}`
      +`&location=${encodeURIComponent(location)}`;
    $('#googleCalendarLink').href=googleUrl;

    const icsLines=[
      'BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//Al Capone Barbearia//Agendamento//PT-BR',
      'CALSCALE:GREGORIAN','METHOD:PUBLISH','BEGIN:VEVENT',
      `UID:${icsEscape(payload.token || code+'@alcapone')}`,
      `DTSTAMP:${icsStamp(new Date())}`,
      `DTSTART:${utcStart}`,`DTEND:${utcEnd}`,
      `SUMMARY:${icsEscape(title)}`,
      `DESCRIPTION:${icsEscape(details)}`,
      `LOCATION:${icsEscape(location)}`,
      'BEGIN:VALARM','TRIGGER:-PT1H','ACTION:DISPLAY','DESCRIPTION:Lembrete: seu horário na Al Capone é em 1 hora.','END:VALARM',
      'BEGIN:VALARM','TRIGGER:-PT30M','ACTION:DISPLAY','DESCRIPTION:Lembrete: seu horário na Al Capone é em 30 minutos.','END:VALARM',
      'END:VEVENT','END:VCALENDAR'
    ];
    $('#downloadCalendar').onclick=()=>{
      const blob=new Blob([icsLines.join('\r\n')+'\r\n'],{type:'text/calendar;charset=utf-8'});
      const url=URL.createObjectURL(blob);const a=document.createElement('a');
      a.href=url;a.download=`al-capone-reserva-${String(code||'horario').replace(/[^a-z0-9_-]/gi,'')}.ics`;
      document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1500);
    };
    let digits=String(phone||'').replace(/\D/g,'');
    if(digits.startsWith('55')) digits=digits.slice(2);
    digits=digits.replace(/^0/,'');
    const whatsappNumber=`55${digits}`;
    const dateLabel=formattedDate(booking.date);
    const finalPriceCents=Math.round(Number(payload.final_price ?? service.price_cents/100)*100);
    const discountCents=Math.round(Number(payload.discount_amount||0)*100);
    const valueLabel=`${service.from_price?'A partir de ':''}${brl(finalPriceCents)}`;
    const couponLine=payload.coupon_code?`\nValor original: ${brl(service.price_cents)}\nCupom: ${payload.coupon_code}\nDesconto: ${brl(discountCents)}`:'';
    const manageUrl=new URL(`minha.html?token=${encodeURIComponent(payload.token)}`,locationHref()).href;
    const message=`AGENDAMENTO CONFIRMADO — AL CAPONE BARBEARIA\n\nHora: ${booking.time}\nData: ${dateLabel}\nProfissional: ${professional.name}\nServiço: ${service.name}\nValor: ${valueLabel}${couponLine}\n\nCódigo da reserva: ${code}\nConsultar ou cancelar: ${manageUrl}`;
    $('#whatsappSummary').href=`https://wa.me/${whatsappNumber}?text=${encodeURIComponent(message)}`;
    $('#whatsappSummary').setAttribute('aria-label','Abrir uma conversa com seu próprio número no WhatsApp, com o resumo do agendamento preenchido. Você só precisa tocar em Enviar.');
  }
  function icsStamp(date){return date.toISOString().replace(/[-:]/g,'').replace(/\.\d{3}Z$/,'Z');}
  function locationHref(){return window.location.href;}

  async function submit(){
    const err=$('#formError');
    const fullName=$('#clientName').value.trim(),phone=$('#clientPhone').value.trim(),email=$('#clientEmail').value.trim();
    if(fullName.length<3||phone.replace(/\D/g,'').length<10||!$('#consent').checked){
      err.textContent='Preencha nome e WhatsApp com DDD e aceite o uso dos dados.';err.hidden=false;return;
    }
    const next=$('#nextBtn');next.disabled=true;next.textContent='CONFIRMANDO...';err.hidden=true;
    try{
      const payload=await rpc('alcapone_agendar',{
        p_profissional_id:booking.professional_id,p_servico_id:booking.service_id,
        p_data:booking.date,p_hora:booking.time,p_nome:fullName,p_whatsapp:phone,
        p_email:email||null,p_observacoes:$('#clientNotes').value.trim()||null,
        p_cupom:booking.coupon?.code||null
      });
      const finalPriceCents=Math.round(Number(payload.final_price ?? state().service.price_cents/100)*100);
      const discountCents=Math.round(Number(payload.discount_amount||0)*100);
      const couponInfo=payload.coupon_code?`<div class="summary-row"><span>VALOR ORIGINAL</span><strong>${brl(state().service.price_cents)}</strong></div><div class="summary-row"><span>CUPOM</span><strong>${esc(payload.coupon_code)}</strong></div><div class="summary-row"><span>DESCONTO</span><strong>− ${brl(discountCents)}</strong></div>`:'';
      $('#confirmationInfo').innerHTML=`<div class="summary-row"><span>CÓDIGO</span><strong>${esc(payload.code)}</strong></div><div class="summary-row"><span>SERVIÇO</span><strong>${esc(payload.service)}</strong></div><div class="summary-row"><span>PROFISSIONAL</span><strong>${esc(payload.professional)}</strong></div><div class="summary-row"><span>DATA/HORA</span><strong>${esc(formattedDate(booking.date))} · ${esc(booking.time)}</strong></div>${couponInfo}<div class="summary-row summary-total"><span>VALOR FINAL</span><strong>${brl(finalPriceCents)}</strong></div>`;
      $('#manageLink').href='minha.html?token='+encodeURIComponent(payload.token);
      prepareConfirmationActions({payload,service:state().service,professional:state().pro,clientName:fullName,phone});
      go(5);
    }catch(e){err.textContent=e.message;err.hidden=false;updateNext();}
  }
  init();
})();
