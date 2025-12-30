package com.xcurenet.pop3reader.service;

import com.xcurenet.pop3reader.mapper.ServiceMapper;
import com.xcurenet.pop3reader.model.MailData;
import lombok.RequiredArgsConstructor;
import lombok.extern.log4j.Log4j2;
import org.springframework.stereotype.Service;

@Log4j2
@Service
@RequiredArgsConstructor
public class MailForwardService {
	private final ServiceMapper serviceMapper;

	public void forward(MailData mail) {
		// TODO
		// 1) REST API 전송
		// 2) Kafka Produce
		// 3) 파일 Drop
		// 4) EMS / EDC 연동
		if (tryRegisterMail(mail.getAccountId(), mail.getMessageId())) {
			log.info("Forward mail: {} / {} / {} / {}", mail.getMessageId(), mail.getSubject(), mail.getFrom(), mail.getSentDate());
		}
	}

	public boolean tryRegisterMail(String accountId, String messageId) {
		try {
			serviceMapper.insert(accountId, messageId);
			return true;
		} catch (Exception e) {
			if (isUniqueConstraint(e)) return false; // 중복 메일
			throw e; // 진짜 에러
		}
	}

	private boolean isUniqueConstraint(Exception e) {
		Throwable t = e;
		while (t != null) {
			if (t.getMessage() != null && t.getMessage().contains("UNIQUE")) return true;
			t = t.getCause();
		}
		return false;
	}
}
