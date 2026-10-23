(() => {
'use strict';
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const theater = $('.theater'), story = $('#scroll-story');
document.documentElement.classList.add('scroll-enabled');
const scenes = [
 {name:'desk',heading:'A little room<br>to build.',title:'Start something good.',description:'Claude does the coding. Buddy keeps your session in view, right by your Mac’s notch.',next:'Take a little break'},
 {name:'away',heading:'Go on.<br>Step away.',title:'Your desk can wait.',description:'The optional iPhone companion is designed to bring requests with you. This connection is still in testing.',next:'Bring up a request'},
 {name:'decision',heading:'Your code.<br>Your call.',title:'One decision. All yours.',description:'Try the sample build below. Buddy never makes the choice for you.',next:'Back to your desk'}
];
let step = 0, decided = false, sound = false, audioContext, toastTimer, helloCount = 0;
let paused = matchMedia('(prefers-reduced-motion: reduce)').matches;
try { paused = paused || localStorage.getItem('buddy-motion') === 'paused'; } catch {}

function tone(kind='tap') {
 if (!sound) return;
 try {
  audioContext ||= new (window.AudioContext || window.webkitAudioContext)();
  audioContext.resume().catch(()=>{});
  const osc = audioContext.createOscillator(), gain = audioContext.createGain(), now = audioContext.currentTime;
  osc.type = 'sine'; osc.frequency.setValueAtTime(kind === 'hello' ? 520 : kind === 'allow' ? 660 : 390, now);
  osc.frequency.exponentialRampToValueAtTime(kind === 'deny' ? 260 : 880, now + .12);
  gain.gain.setValueAtTime(0,now); gain.gain.linearRampToValueAtTime(.045,now+.015); gain.gain.exponentialRampToValueAtTime(.001,now+.2);
  osc.connect(gain); gain.connect(audioContext.destination);osc.start();osc.stop(now+.22);
 } catch { sound = false; updateSound(); }
}
function toast(message){clearTimeout(toastTimer);$('#scene-toast').textContent=message;$('#scene-toast').classList.add('visible');toastTimer=setTimeout(()=>$('#scene-toast').classList.remove('visible'),3500);}
function resetDecision(){
 decided=false;$$('[data-mirror]').forEach(b=>b.hidden=b.dataset.mirror==='replay');$('#phone-title').innerHTML='One little<br>decision.';$('#phone-description').textContent='Claude would like to run your build.';$('.phone-actions').hidden=false;$('#replay').hidden=true;
 $('#notch-title').textContent=step===0?'Claude is working.':'Your decision is needed.';$('#notch-subtitle').textContent=step===0?'I’ll keep an eye on things.':'A little check before the next step.';
 $('#terminal-status').innerHTML='<span class="terminal-prompt">›</span> Waiting for your next move.<b class="cursor"></b>';
}
function renderScene(next, updateRange=true, announce=true){
 const changed=next!==step;step=next;$('#accessible-decisions').hidden=step!==2;const scene=scenes[step];theater.dataset.scene=scene.name;
 $('#scene-word').innerHTML=scene.heading;$('#chapter-count').textContent=`0${step+1} / 03`;$('#chapter-title').textContent=scene.title;$('#chapter-description').textContent=scene.description;
 $('#next-scene').innerHTML=scene.next+' <svg><use href="#arrow"/></svg>';
 $$('[data-step]').forEach(button=>button.setAttribute('aria-pressed',String(Number(button.dataset.step)===step)));

 $$('button[data-decision]').forEach(button=>button.disabled=step!==2||decided);
 $('#phone').setAttribute('aria-hidden',String(step===0));$('#replay').tabIndex=step===0?-1:0;
 if(changed){clearTimeout(toastTimer);$('#scene-toast').classList.remove('visible');resetDecision();$$('button[data-decision]').forEach(button=>button.disabled=step!==2);if(announce)tone();}
}
const clamp = value => Math.max(0, Math.min(1, value));
let scrollFrame = 0;
let storyStart = 0, storyDistance = 1, cueAtEnd = null, stageSize = '';
function storyMetrics() {
 return { start: storyStart, distance: storyDistance };
}
function syncScroll() {
 scrollFrame = 0;
 const {start, distance} = storyMetrics();
 if(distance <= 0)return;
 const progress = clamp((scrollY - start) / distance);
 theater.style.setProperty('--story-progress', progress);
 const next = progress < .30 ? 0 : progress < .65 ? 1 : 2;
 if(next !== step) renderScene(next, false, false);
 const atEnd = progress > .85;
 if(atEnd !== cueAtEnd){cueAtEnd = atEnd;$('.scroll-cue').innerHTML = atEnd ? 'Keep scrolling to meet Block <span aria-hidden="true">↓</span>' : 'Scroll to explore <span aria-hidden="true">↓</span>';}
}
function jumpToScene(next) {
 const {start, distance} = storyMetrics();
 if(distance <= 0){renderScene(next, false, false);theater.style.setProperty('--story-progress',next/2);return;}
 window.scrollTo({top: start + distance * [0, .44, .78][next], behavior: paused ? 'instant' : 'smooth'});
}
$$('[data-step]').forEach(button=>button.addEventListener('click',()=>jumpToScene(Number(button.dataset.step))));
$('#next-scene').addEventListener('click',()=>jumpToScene((step+1)%3));
function fitStage() {
 const mobile = innerWidth <= 700;
 const width = mobile ? 390 : 1440, height = mobile ? 660 : 720;
 const world = $('#world');
 const scale = Math.min(world.clientWidth / width, world.clientHeight / height);
 const stage = $('.world-stage');
 const size = `${width}:${height}:${scale}`;
 if(size !== stageSize){stageSize = size;stage.style.width = width + 'px';stage.style.height = height + 'px';stage.style.transform = `translateX(-50%) scale(${scale})`;}
 storyStart = story.getBoundingClientRect().top + scrollY;
 storyDistance = story.offsetHeight - $('.story-pin').offsetHeight;
 syncScroll();
}
window.addEventListener('scroll',()=>{if(!scrollFrame)scrollFrame=requestAnimationFrame(syncScroll);},{passive:true});
window.addEventListener('resize',fitStage);
new ResizeObserver(fitStage).observe($('#world'));
$$('button[data-decision]').forEach(button=>button.addEventListener('click',()=>{
 if(step!==2||decided)return;decided=true;const allowed=button.dataset.decision==='allow';
 $('#phone-title').innerHTML=allowed?'And we’re<br>off again.':'Your call.<br>Respected.';$('#phone-description').textContent=allowed?'You approved the sample build. Back to the good part.':'You declined. The sample command will not run.';
 $('.phone-actions').hidden=true;$('#replay').hidden=false;$$('[data-mirror]').forEach(b=>b.hidden=b.dataset.mirror!=='replay');$('[data-mirror="replay"]').focus({preventScroll:true});
 $('#notch-title').textContent=allowed?'Back to building.':'Request declined.';$('#notch-subtitle').textContent=allowed?'A little progress, a little peace.':'Your decisions stay yours.';
 $('#terminal-status').textContent=allowed?'› Sample build approved.':'› Sample build declined.';
 $('#chapter-title').textContent=allowed?'Good call. Keep going.':'A “no” is a decision, too.';$('#chapter-description').textContent='That was a simulation. In the app, your decision goes back to the waiting Claude Code session.';
 toast(allowed?'Approved. Now, where were we?':'No means no. Buddy gets it.');tone(allowed?'allow':'deny');
}));
$('#replay').addEventListener('click',()=>{resetDecision();$$('button[data-decision]').forEach(b=>b.disabled=false);$('#chapter-title').textContent=scenes[2].title;$('#chapter-description').textContent=scenes[2].description;$('[data-mirror="deny"]').focus({preventScroll:true});});
$('#pet-hero').addEventListener('click',()=>{const greetings=['Oh, hi. I was hoping you’d do that.','Big idea? I’m all ears. Well… eyes.','Still here. Still rooting for you.'];toast(greetings[helloCount++%greetings.length]);$('#pet-hero').classList.remove('greeting');void $('#pet-hero').offsetWidth;$('#pet-hero').classList.add('greeting');$('#pet-hint').textContent='we’re friends now.';tone('hello');});
$('#light-toggle').addEventListener('click',()=>{const evening=theater.classList.toggle('evening');$('#light-toggle').setAttribute('aria-pressed',String(evening));$('#light-toggle').setAttribute('aria-label',evening?'Switch to daylight':'Switch to evening');tone();});
function updateSound(){const button=$('#sound-toggle');button.setAttribute('aria-pressed',String(sound));button.setAttribute('aria-label',sound?'Turn sound off':'Turn sound on');button.querySelector('span').textContent=sound?'Sound on':'Sound off';}
$('#sound-toggle').addEventListener('click',()=>{sound=!sound;updateSound();if(sound)tone('hello');});
function updateMotion(){document.documentElement.classList.toggle('paused',paused);$('#motion-toggle').setAttribute('aria-pressed',String(paused));$('#motion-toggle').setAttribute('aria-label',paused?'Resume motion':'Pause motion');}
$('#motion-toggle').addEventListener('click',()=>{paused=!paused;updateMotion();try{localStorage.setItem('buddy-motion',paused?'paused':'running');}catch{}});
matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change',event=>{if(event.matches){paused=true;updateMotion();}fitStage();});
const stateInfo = {
 idle:['Ready for the next idea.','#5ca8ff',''],working:['Claude is working on your project.','#ffb32e','…'],thinking:['Thinking through the next step.','#ab87ff','…'],searching:['Looking around your project.','#2eccC7',''],approval:['A request needs your decision.','#ff7a24','!'],question:['Claude has a question for you.','#ff73bd','?'],error:['Something went wrong. Check the session.','#ef383d','!'],finished:['That part is done. Nice work.','#54d166','✓'],rateLimited:['Waiting on the agent’s rate limit.','#f5de52','…'],sleeping:['Quiet for a while. Time for a rest.','#6b75db','z'],dizzy:['Too many boops! Give me a moment.','#ccd1e0','↻']
};
let emoteTimer;
function setCharacterState(mood){
 clearTimeout(emoteTimer);const space=$('#pet-space');delete space.dataset.emote;space.classList.remove('happy');space.dataset.mood=mood;
 const [message,color,badge]=stateInfo[mood];$('#pet-speech').textContent=message;space.style.setProperty('--state-color',color);$('#state-badge').textContent=badge;
 $$('button[data-mood]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.mood===mood)));
}
$$('button[data-mood]').forEach(button=>button.addEventListener('click',()=>{setCharacterState(button.dataset.mood);tone();}));
$$('[data-emote]').forEach(button=>button.addEventListener('click',()=>{
 clearTimeout(emoteTimer);const space=$('#pet-space');space.dataset.emote=button.dataset.emote;$('#pet-speech').textContent=button.textContent+' — a little expression, then back to the session.';
 emoteTimer=setTimeout(()=>{delete space.dataset.emote;$('#pet-speech').textContent=stateInfo[space.dataset.mood][0];},2400);tone('hello');
}));
setCharacterState('working');
$$('[data-mirror]').forEach(button=>button.addEventListener('click',()=>{if(button.dataset.mirror==='replay')$('#replay').click();else $('button[data-decision="'+button.dataset.mirror+'"]').click();}));
const featureContent={
 question:'<h3>Which theme should I use?</h3><p>Claude needs a little direction before continuing.</p><div class="sample-choices"><button data-answer="Light theme selected for this sample.">Light</button><button data-answer="Dark theme selected for this sample.">Dark</button><button data-answer="In the app, you can type your own answer or answer in the terminal.">Another answer</button></div>',
 plan:'<h3>Claude has a plan.</h3><ol><li>Inspect the existing navigation.</li><li>Add keyboard focus states.</li><li>Run the project’s checks.</li></ol><p>You choose how edits are handled.</p><div class="sample-choices"><button data-answer="Sample plan sent back for changes.">Change plan</button><button data-answer="Sample plan approved. The agent would ask for subsequent permissions as usual.">Go · ask each time</button><button data-answer="Sample plan approved with auto-accept edits. This is an explicit permission-mode choice, not Buddy deciding for you.">Go · auto-accept edits</button></div>',
 sessions:'<h3>Two projects. One glance.</h3><p>Select the session you want to follow.</p><div class="sample-choices session-choices"><button data-answer="Showing website: Claude is working on navigation.">website <span>Working</span></button><button data-answer="Showing api-service: a question is waiting for your answer.">api-service <span>Needs your answer</span></button></div>'
};
let activeFeature='question';
function showFeature(name){activeFeature=name;$('#action-content').innerHTML=featureContent[name];$('#action-feedback').textContent='';$('#action-reset').hidden=true;$$('[data-feature]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.feature===name)));}
$$('[data-feature]').forEach(button=>button.addEventListener('click',()=>showFeature(button.dataset.feature)));
$('#action-content').addEventListener('click',event=>{const button=event.target.closest('[data-answer]');if(!button)return;$('#action-feedback').textContent=button.dataset.answer;$('#action-reset').hidden=false;$$('#action-content button').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));tone();});
$('#action-reset').addEventListener('click',()=>{showFeature(activeFeature);$('#action-content button').focus({preventScroll:true});});showFeature('question');
let petCount=0;$('#pet-button').addEventListener('click',()=>{const space=$('#pet-space');$('#pet-speech').textContent=space.dataset.mood==='sleeping'?'Five more minutes? Please?':['Oh. You’re my favorite human.','That counts as a little break.','Okay, back to making something great.'][petCount++%3];space.classList.remove('happy');void space.offsetWidth;space.classList.add('happy');tone('hello');});
let pointerFrame=0;document.addEventListener('pointermove',event=>{if(paused||event.pointerType==='touch'||pointerFrame)return;pointerFrame=requestAnimationFrame(()=>{pointerFrame=0;document.documentElement.style.setProperty('--eye-x',((event.clientX/innerWidth-.5)*5)+'px');document.documentElement.style.setProperty('--eye-y',((event.clientY/innerHeight-.5)*5)+'px');});},{passive:true});
// Pause ambient animation when its scene is outside the viewport.
const observer=new IntersectionObserver(entries=>entries.forEach(entry=>entry.target.classList.toggle('offstage',!entry.isIntersecting)),{rootMargin:'100px'});observer.observe(theater);observer.observe($('.playroom'));observer.observe($('.get-buddy'));
const style=document.createElement('style');style.textContent='.offstage *{animation-play-state:paused!important}';document.head.append(style);
document.addEventListener('visibilitychange',()=>document.body.classList.toggle('offstage',document.hidden));
updateMotion();renderScene(0,true,false);fitStage();
})();
